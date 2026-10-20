#!/bin/bash
# mesa: panfrost converts a private AFBC texture to u-interleaved on its first CPU write instead
# of a staging copy, a GPU blit and a flush on every write (docs/tuning/launch-latency.md). Qt
# Quick popups such as the Plasma start menu made ~2500 GPU submissions for their first frame.
# Also configures PanVK Vulkan driver support for Mali-G76 (Bifrost v7).
#
#   sudo system/mesa/install.sh [--so FILE] [--vk-so FILE] [--remove]
#
# The patched libgallium goes to /usr/local/lib/l410-mesa, listed in /etc/ld.so.conf.d before the
# multiarch directory; Debian's package stays untouched. A Mesa upgrade changes the library name
# (libgallium-<version>.so), so a stale copy is simply not used any more; an apt hook says so,
# then rebuild with build.sh. Without --so, the prebuilt file from the release is used when it
# matches the installed Mesa. Log out and in afterwards (KWin and plasmashell together).
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
H=$L410_SYSTEM/mesa
L=/usr/local/lib/l410-mesa C=/etc/ld.so.conf.d/00-l410-mesa.conf
ICD=/etc/vulkan/icd.d/00-panfrost.json

if [ "$1" = --remove ]; then
	rm -f $C /etc/apt/apt.conf.d/99l410-mesa-check "$ICD" \
	      /etc/environment.d/10-panvk.conf /etc/profile.d/panvk.sh
	rm -rf $L
	ldconfig
	echo "removed; log out and in to drop it from running processes"
	exit 0
fi

# 1. Vulkan (PanVK) environment configuration (supports stock and custom packages)
mkdir -p /etc/environment.d /etc/profile.d
echo "PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1" > /etc/environment.d/10-panvk.conf
cat << 'EOF' > /etc/profile.d/panvk.sh
# L410: enable PanVK on Mali-G76 (Bifrost v7)
export PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1
EOF
chmod 644 /etc/environment.d/10-panvk.conf /etc/profile.d/panvk.sh

# 2. Gallium driver installation
SO=
VK_SO=
while [ $# -gt 0 ]; do
	case $1 in
	--so) SO=$(readlink -f "$2"); shift 2 ;;
	--vk-so) VK_SO=$(readlink -f "$2"); shift 2 ;;
	*) shift ;;
	esac
done

if dpkg-query -W mesa-libgallium:arm64 > /dev/null 2>&1; then
	ver=$(dpkg-query -W -f='${Version}' mesa-libgallium:arm64)
	lib=libgallium-${ver#*:}.so
	if [ -z "$SO" ] && grep -qs " $lib$" "$L410_SYSTEM/assets.sha256" && fetch_asset $lib /tmp/$lib; then
		SO=/tmp/$lib
	fi
	if [ -n "$SO" ]; then
		[ "$(basename "$SO")" = $lib ] || { echo "$SO is not $lib (installed Mesa $ver)" >&2; exit 1; }
		install -D -m 644 "$SO" $L/$lib
		echo $L > $C
		ldconfig
		install -m 755 $H/l410-mesa-check $L/
		install -m 644 $H/99l410-mesa-check /etc/apt/apt.conf.d/
		rm -f /tmp/$lib
		echo "mesa: $L/$lib"
	fi
fi

# 3. PanVK Vulkan driver installation (if provided)
if [ -n "$VK_SO" ] && [ -f "$VK_SO" ]; then
	install -D -m 644 "$VK_SO" $L/libvulkan_panfrost.so
	mkdir -p /etc/vulkan/icd.d
	cat << EOF > "$ICD"
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "$L/libvulkan_panfrost.so",
        "api_version": "1.3.0"
    }
}
EOF
	chmod 644 "$ICD"
	echo "vulkan: $L/libvulkan_panfrost.so -> $ICD"
fi

echo "mesa & panvk configuration installed successfully"
