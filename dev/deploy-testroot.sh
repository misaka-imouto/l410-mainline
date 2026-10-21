#!/bin/bash
# Deploy a rootfs/mkrootfs.sh tarball plus a kernel bundle to the L410 test partition and arm
# an unattended verification boot.
#
# Run as root ON the L410 under the factory system (the partition is rewritten while it is not
# mounted, the test root is only booted once through GRUB's next_entry):
#
#   sudo dev/deploy-testroot.sh l410-debian-trixie.tar.xz BUNDLE [PART]
#
#   PART                     default /dev/sdd6 (never sdd1-sdd4: ESP, SYSBOOT, factory root)
#   L410_SWAP=4G             swap file size in the test root, 0 for none (default 4G)
#   L410_USER=zhtsg          desktop user, for the autologin session
#   L410_FW_LIST=...         rootfs/firmware.list of this repository (vendor firmware to copy
#                            from the running factory system)
#   L410_KEEP_BOOTCFG=1      do not touch /boot/l410/boot.cfg after install-kernel.sh (keeps a
#                            command line prepared by hand)
#
# What it does beyond unpacking: root fstab, vendor firmware, swap file, the kernel bundle in
# /boot/l410, /etc/modules-load.d/l410.conf for the TZ/fingerprint/VENC modules, the
# l410-firstboot.service verification boot, l410-root-revert.service as the reboot backstop,
# and masking of l410-watchdog-off.service so the deadman keeps running during the tests.
set -e
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
TOP=$(dirname "$HERE")
TARBALL=${1:?usage: deploy-testroot.sh ROOTFS.tar.xz BUNDLE [PART]}
BUNDLE=${2:?usage: deploy-testroot.sh ROOTFS.tar.xz BUNDLE [PART]}
PART=${3:-/dev/sdd6}
EXTRA_KO=${4:-}
SWAP=${L410_SWAP:-4G}
USER_=${L410_USER:-zhtsg}
FW_LIST=${L410_FW_LIST:-$TOP/rootfs/firmware.list}
M=${M:-/mnt/target}

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$TARBALL" ] || { echo "no such tarball: $TARBALL" >&2; exit 1; }
[ -f "$BUNDLE/Image" ] && [ -f "$BUNDLE/kver" ] || { echo "not a kernel bundle: $BUNDLE" >&2; exit 1; }
case $(basename "$PART") in
sdd[1-4] | sda* | sdb* | sdc*) echo "refusing $PART: ESP, SYSBOOT, factory root or a firmware LUN" >&2; exit 1 ;;
esac
[ -b "$PART" ] || { echo "$PART is not a block device" >&2; exit 1; }
SIZE=$(blockdev --getsize64 "$PART")
[ "$SIZE" -ge $((20 * 1024 * 1024 * 1024)) ] || { echo "$PART is smaller than 20 GiB" >&2; exit 1; }

echo "== formatting $PART ($((SIZE >> 30)) GiB): everything on it is lost"
mkfs.ext4 -F -q -L DEBIAN "$PART"
UUID=$(blkid -s UUID -o value "$PART")
mkdir -p "$M"
mount "$PART" "$M"
trap 'sync; umount "$M" 2>/dev/null || true' EXIT

echo "== unpacking $TARBALL"
tar --numeric-owner --xattrs --xattrs-include='*' -xpf "$TARBALL" -C "$M"

echo "== fstab"
echo "UUID=$UUID / ext4 errors=remount-ro,relatime 0 1" > "$M/etc/fstab"

echo "== vendor firmware from the factory system"
copied=0
if [ -f "$FW_LIST" ]; then
	while read -r f _; do
		case $f in '' | '#'*) continue ;; esac
		if [ -e "/$f" ]; then
			mkdir -p "$M/$(dirname "$f")"
			cp -a "/$f" "$M/$(dirname "$f")/"
			copied=$((copied + 1))
		else
			echo "   warning: /$f missing in the factory system" >&2
		fi
	done < "$FW_LIST"
	echo "   copied $copied firmware entries"
else
	echo "   no firmware list at $FW_LIST, skipped" >&2
fi

if [ "$SWAP" != 0 ]; then
	echo "== swap file $SWAP"
	fallocate -l "$SWAP" "$M/swapfile"
	chmod 600 "$M/swapfile"
	mkswap "$M/swapfile" >/dev/null
	echo "/swapfile none swap defaults 0 0" >> "$M/etc/fstab"
fi

echo "== kernel bundle"
KVER=$(cat "$BUNDLE/kver")
rm -rf "$M/boot/l410.prev" "$M/lib/modules/$KVER"
install -d "$M/boot/l410"
install -m 644 "$BUNDLE/Image" "$BUNDLE/l410.dtb" "$BUNDLE/initrd.img" "$M/boot/l410/"
[ -f "$BUNDLE/config" ] && install -m 644 "$BUNDLE/config" "$M/boot/l410/config-$KVER"
tar --keep-directory-symlink -xzf "$BUNDLE/modules.tar.gz" -C "$M/"
if [ -n "$EXTRA_KO" ]; then
	echo "== extra module $EXTRA_KO"
	install -d "$M/lib/modules/$KVER/extra"
	install -m 644 "$EXTRA_KO" "$M/lib/modules/$KVER/extra/$(basename "$EXTRA_KO")"
fi
chroot "$M" depmod -a "$KVER"

if [ "${L410_KEEP_BOOTCFG:-0}" != 1 ]; then
	echo "== boot.cfg"
	cat > "$M/boot/l410/boot.cfg" << EOF
echo 'L410 kernel $KVER (first-boot verification)'
linux /boot/l410/Image root=UUID=$UUID ro rootwait ignore_loglevel printk.devkmsg=on panic=10 nokaslr efi=noruntime log_buf_len=16M clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 l410_deadman=2400
initrd /boot/l410/initrd.img
devicetree /boot/l410/l410.dtb
EOF
fi

echo "== test boot harness"
printf 'tzdriver\nhuawei_fingerprint\nhisi-venc\n' > "$M/etc/modules-load.d/l410.conf"
install -m 755 "$HERE/l410-firstboot.sh" "$M/usr/local/sbin/l410-firstboot.sh"
install -m 644 "$HERE/systemd/l410-firstboot.service" "$HERE/systemd/l410-root-revert.service" \
	"$M/etc/systemd/system/"
mkdir -p "$M/etc/systemd/system/graphical.target.wants" "$M/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/l410-firstboot.service "$M/etc/systemd/system/graphical.target.wants/l410-firstboot.service"
ln -sf /etc/systemd/system/l410-root-revert.service "$M/etc/systemd/system/multi-user.target.wants/l410-root-revert.service"
# keep the deadman watchdog armed for the test boot (the install normally stops it)
ln -sf /dev/null "$M/etc/systemd/system/l410-watchdog-off.service"
echo "   user $USER_, swap $SWAP"

# a test root is a bad place for a shared machine-wide journal: keep the logs on this partition
install -d "$M/var/log/journal"

echo "== GRUB entry"
if [ -x "$TOP/boot/grub-entry.sh" ]; then
	"$TOP/boot/grub-entry.sh" "$UUID" --once
else
	echo "   boot/grub-entry.sh not found, GRUB entry must already exist for UUID $UUID" >&2
	grep -q "$UUID" /boot/grub/custom.cfg 2>/dev/null ||
		echo "   WARNING: /boot/grub/custom.cfg does not mention $UUID" >&2
	grub-editenv /boot/grub/grubenv set next_entry=l410-debian
fi

sync
echo "== done: rootfs on $PART (UUID $UUID), kernel $KVER"
echo "   next boot: l410-debian (one shot), verification log will be /var/log/l410-firstboot.log"
