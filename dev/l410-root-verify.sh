#!/bin/bash
# Root-mode bring-up verification for the L410 6.18 kernel.
#
# Runs from l410-root-verify.service on a test boot into a real userspace (l410.mode=root)
# and writes everything to $LOG on the test root. It reboots the machine at the end unless
# --no-reboot is given: no network device works under 6.18 yet (the RTL8168 has no cable, the
# Hi1103 PCIe endpoint is not enumerated), so a test boot is only reachable through the log it
# leaves behind. l410-root-revert.service is the fallback if this script never finishes, and
# l410_deadman=<seconds> on the kernel command line resets the machine if the kernel hangs.
#
#   l410-root-verify.sh [--no-reboot] [--desktop-wait SECONDS] [--log FILE] [--user NAME]

LOG=/l410-root-verify.log
REBOOT=1
DESKTOP_WAIT=120
USER_=zhtsg
while [ $# -gt 0 ]; do
	case $1 in
	--no-reboot) REBOOT=0; shift ;;
	--desktop-wait) DESKTOP_WAIT=$2; shift 2 ;;
	--log) LOG=$2; shift 2 ;;
	--user) USER_=$2; shift 2 ;;
	*) echo "usage: $0 [--no-reboot] [--desktop-wait S] [--log FILE] [--user NAME]" >&2; exit 2 ;;
	esac
done
exec > "$LOG" 2>&1

UID_=$(id -u "$USER_" 2>/dev/null || echo 1000)
RT=/run/user/$UID_

sec() { echo; echo "===== $*"; }
# root command with timeout:  run T SEC CMD...
run() {
	local t=20
	[ "$1" = "--t" ] && { t=$2; shift 2; }
	echo "\$ $*"
	timeout "$t" "$@" 2>&1
	echo "(rc=$?)"
}
# command as the desktop user, no session bus:  u SEC CMD...
u() {
	local t=$1; shift
	echo "\$ [$USER_] $*"
	runuser -u "$USER_" -- env XDG_RUNTIME_DIR=$RT DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus \
		timeout "$t" "$@" 2>&1
	echo "(rc=$?)"
}
# command in the user's X session:  x SEC CMD...
x() {
	local t=$1; shift
	echo "\$ [$USER_ X] $*"
	runuser -u "$USER_" -- env DISPLAY=:0 XAUTHORITY="${XAUTH:-/home/$USER_/.Xauthority}" \
		XDG_RUNTIME_DIR=$RT DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus \
		timeout "$t" "$@" 2>&1
	echo "(rc=$?)"
}

sec "identity"
date -Is
echo "kernel: $(uname -r) $(uname -m)"
echo "cmdline: $(cat /proc/cmdline)"
echo "boot id: $(cat /proc/sys/kernel/random/boot_id)"
echo "uptime: $(cat /proc/uptime)"

sec "systemd"
run systemctl is-system-running
run systemctl --failed --no-pager
echo "default target: $(systemctl get-default 2>&1)"
run systemctl is-active graphical.target display-manager.service lightdm.service
echo "--- logind sessions"
run loginctl list-sessions --no-legend

sec "modules"
run --t 5 sh -c 'lsmod | grep -E "^(panfrost|tzdriver|huawei_fingerprint|hisi_venc|hi110x|r8169|kirin)|^snd" | sort'
run sh -c 'ls /etc/modules-load.d/ 2>/dev/null'

sec "display: DRM"
run sh -c 'for c in /sys/class/drm/card*/; do echo "$(basename $c) status=$(cat $c/status 2>/dev/null) enabled=$(cat $c/enabled 2>/dev/null)"; done'
run sh -c 'for f in /sys/kernel/debug/dri/*/name; do echo "$f: $(cat $f)"; done'
run --t 5 sh -c 'grep -iE "panfrost|kirin990|dss|dsi" /proc/interrupts'
run --t 5 sh -c 'dmesg | grep -iE "panfrost|mali|kbase" | tail -20'

sec "GPU userspace stack (this rootfs is the factory UOS userland)"
run ls -l /dev/mali0 /dev/dri/by-path/ 2>&1
run --t 5 sh -c 'for f in /usr/lib/aarch64-linux-gnu/libGLESv2.so.2 /usr/lib/aarch64-linux-gnu/libEGL.so.1 /usr/lib/aarch64-linux-gnu/libGL.so.1; do echo "$f -> $(readlink -f $f 2>/dev/null)"; done'
run --t 5 sh -c 'ls /usr/lib/aarch64-linux-gnu/dri/ | grep -iE "panfrost|swrast|kms"'
run --t 5 sh -c 'dpkg -l | grep -E "^ii\s+(mesa-utils|libgl1-mesa-dri|fprintd|libfprint0|pulseaudio|lightdm) "'

sec "display: X server"
i=0
while [ $i -lt "$DESKTOP_WAIT" ]; do
	[ -S /tmp/.X11-unix/X0 ] && break
	sleep 1
	i=$((i + 1))
done
echo "waited ${i}s for /tmp/.X11-unix/X0"
run ls -l /tmp/.X11-unix/
XAUTH=/home/$USER_/.Xauthority
if [ ! -e "$XAUTH" ]; then
	for f in /var/run/lightdm/root/:0 /run/lightdm/root/:0; do
		[ -e "$f" ] || continue
		xauth -f "$f" extract - :0 > /run/l410-xauth 2>/dev/null && chmod 644 /run/l410-xauth && XAUTH=/run/l410-xauth
		break
	done
fi
echo "XAUTHORITY: $XAUTH ($( [ -e "$XAUTH" ] && echo present || echo missing ))"
run --t 15 x 15 xdpyinfo
run --t 15 x 15 xrandr --verbose
run --t 30 x 30 glxinfo -B
run --t 20 x 20 glxgears -info
run --t 20 x 20 sh -c 'glxinfo -B | grep -E "OpenGL (renderer|vendor|version|core)"'

sec "display: compositor / session"
run --t 5 sh -c 'ps -eo pid,user,comm,args --sort=pid | grep -E "Xorg|lightdm|startdde|dde-|kwin|pulseaudio|wireplumber|pipewire" | grep -v grep'
run --t 15 systemctl status lightdm --no-pager -l
echo "--- lightdm log"
run --t 5 sh -c "tail -80 /var/log/lightdm/lightdm.log 2>/dev/null || echo no-lightdm-log"
echo "--- xsession errors"
run --t 5 sh -c "tail -60 /home/$USER_/.xsession-errors 2>/dev/null || echo no-xsession-errors"

sec "audio: ALSA"
run cat /proc/asound/cards
run cat /proc/asound/pcm
run --t 10 aplay -l
run --t 10 aplay -L
run --t 5 sh -c 'for d in /proc/asound/card*/eld#*; do echo "--- $d"; cat $d; done 2>/dev/null || echo no-eld'

sec "audio: playback (silence, 3 s)"
run --t 15 aplay -D default -f S16_LE -r 48000 -c 2 /dev/zero
run --t 15 aplay -D plughw:CARD=hi6405,DEV=0 -f S16_LE -r 48000 -c 2 /dev/zero
run --t 15 aplay -D plughw:CARD=hisihdmi,DEV=0 -f S16_LE -r 48000 -c 2 /dev/zero
run --t 15 aplay -D plughw:CARD=hisihdmi,DEV=1 -f S16_LE -r 48000 -c 2 /dev/zero

sec "audio: userspace"
u 10 pactl info
u 10 pactl list cards short
u 10 pactl list sinks short
run systemctl is-active pulseaudio.service pulseaudio.socket

sec "fingerprint"
run ls -l /dev/tc_ns_client /dev/fingerprint
run --t 5 sh -c 'ls -l /sys/class/misc/ | grep -i finger'
run --t 15 systemctl status hwfp_init --no-pager -l
run --t 15 sh -c 'journalctl -b -u hwfp_init --no-pager | tail -40'
u 20 fprintd-list "$USER_"
u 20 fprintd-verify "$USER_"

sec "video encoder"
run --t 5 sh -c 'ls -l /dev/video* 2>/dev/null; for v in /sys/class/video4linux/*/name; do echo "$v: $(cat $v)"; done'

sec "network"
run ip -br addr
run --t 5 sh -c 'for i in /sys/class/net/*; do echo "$(basename $i) carrier=$(cat $i/carrier 2>/dev/null) oper=$(cat $i/operstate)"; done'
run --t 10 ethtool enp1s0
run systemctl is-active NetworkManager frpc
run --t 5 sh -c 'lsmod | grep -E "^(hi110x|r8169)"'

sec "power / sleep"
run cat /sys/power/mem_sleep
run --t 5 sh -c 'for w in /sys/class/wakeup/*; do [ -e $w/name ] && echo "$(cat $w/name)"; done | sort | tr "\n" " "'
echo
run cat /sys/kernel/l410_deadman/timeout

sec "kernel messages (errors)"
run --t 10 sh -c 'dmesg | grep -iE "call trace|oops|panic|BUG:|WARNING:|firmware.*(fail|error)|-ENOENT|-ENODEV|-110|failed" | tail -60'

sec "tail of dmesg"
run --t 10 sh -c 'dmesg | tail -80'

dmesg > /l410-root-dmesg.log 2>&1
journalctl -b --no-pager > /l410-root-journal.log 2>&1
echo
echo "===== done $(date -Is)"
sync
if [ "$REBOOT" = 1 ]; then
	sleep 2
	echo "l410-root-verify: rebooting" > /dev/kmsg
	reboot -f
fi
