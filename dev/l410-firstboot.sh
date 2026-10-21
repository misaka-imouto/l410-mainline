#!/bin/bash
# First-boot verification of the L410 6.18 kernel on a real desktop root (KDE Plasma Wayland).
#
# Runs from l410-firstboot.service at boot of the test root, writes everything to LOG and
# reboots (unless l410.keep is on the kernel command line). There is no usable network device
# under 6.18 yet (RTL8168 has no cable, Hi1103 does not enumerate), so the log is the only way
# to see what happened. l410-root-revert.service and l410_deadman=<seconds> are the backstops.
#
#   l410-firstboot.sh [--no-reboot] [--desktop-wait SECONDS] [--skip-graphics] [--user NAME]

LOG=/var/log/l410-firstboot.log
KEEP=0
DESKTOP_WAIT=300
GRAPHICS=1
USER_=zhtsg
while [ $# -gt 0 ]; do
	case $1 in
	--no-reboot) KEEP=1; shift ;;
	--desktop-wait) DESKTOP_WAIT=$2; shift 2 ;;
	--skip-graphics) GRAPHICS=0; shift ;;
	--user) USER_=$2; shift 2 ;;
	*) echo "usage: $0 [--no-reboot] [--desktop-wait S] [--skip-graphics] [--user NAME]" >&2; exit 2 ;;
	esac
done
grep -q 'l410.keep' /proc/cmdline && KEEP=1
exec > "$LOG" 2>&1

UID_=$(id -u "$USER_" 2>/dev/null || echo 1000)
RT=/run/user/$UID_
sec() { echo; echo "===== $*"; }
run() {
	local t=20
	[ "$1" = "--t" ] && { t=$2; shift 2; }
	echo "\$ $*"
	timeout "$t" "$@" 2>&1
	echo "(rc=$?)"
}
# user session command (Wayland + PipeWire): u SEC CMD...
u() {
	local t=$1 wl; shift
	wl=$(basename "$(ls -1 "$RT"/wayland-* 2>/dev/null | head -1)" 2>/dev/null)
	echo "\$ [$USER_ ${wl:-no-wayland}] $*"
	runuser -u "$USER_" -- env XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="${wl:-wayland-0}" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" timeout "$t" "$@" 2>&1
	echo "(rc=$?)"
}
arm_deadman() { [ -e /sys/kernel/l410_deadman/timeout ] && { echo 2400 > /sys/kernel/l410_deadman/timeout; echo "deadman: $(cat /sys/kernel/l410_deadman/timeout)"; }; }

sec "identity"
date -Is
echo "kernel: $(uname -r) $(uname -m)"
echo "cmdline: $(cat /proc/cmdline)"
echo "uptime: $(cat /proc/uptime)"
arm_deadman

sec "first-boot hardware configuration (system/install.sh hardware fingerprint)"
if [ -x /opt/l410/system/install.sh ]; then
	# the stage re-enables l410-watchdog-off.service, and enable fails on a masked unit (set -e)
	systemctl unmask l410-watchdog-off.service >/dev/null 2>&1 || true
	L410_USER="$USER_" timeout 300 bash /opt/l410/system/install.sh hardware fingerprint 2>&1 | tail -40
	rc=${PIPESTATUS[0]}
	arm_deadman
	# the deadman is the reset backstop of this boot: mask the unit that stops it
	systemctl mask --now l410-watchdog-off.service >/dev/null 2>&1 || true
	arm_deadman
	echo "install.sh rc=$rc"
else
	echo "/opt/l410/system/install.sh missing"
fi
run systemctl is-active l410-watchdog-off.service
arm_deadman

sec "systemd"
run systemctl is-system-running
run systemctl --failed --no-pager
run systemctl is-active graphical.target sddm.service
run loginctl list-sessions --no-legend

sec "modules"
run --t 5 sh -c 'lsmod | grep -E "^(panfrost|tzdriver|huawei_fingerprint|hisi_venc|hi110x|r8169)|^snd" | sort'
run cat /etc/modules-load.d/l410.conf

sec "display: DRM"
run sh -c 'for c in /sys/class/drm/card*/; do echo "$(basename $c) status=$(cat $c/status 2>/dev/null) enabled=$(cat $c/enabled 2>/dev/null)"; done'
run sh -c 'for c in /sys/class/drm/card*-eDP-1/modes; do echo "$c: $(tr "\n" " " < $c)"; done'
run sh -c 'for f in /sys/kernel/debug/dri/*/name; do echo "$f: $(cat $f)"; done'
run --t 5 sh -c 'grep -iE "panfrost|kirin-dss" /proc/interrupts'
run --t 5 sh -c 'dmesg | grep -iE "panfrost|kirin990-dss|mali" | tail -20'

sec "desktop: wait for Plasma session"
i=0
while [ $i -lt "$DESKTOP_WAIT" ]; do
	[ -S "$RT/wayland-0" ] && pgrep -u "$UID_" -f kwin_wayland >/dev/null && break
	sleep 2
	i=$((i + 2))
done
echo "waited ${i}s"
run ls -l "$RT/"
run --t 5 ps -eo pid,user,comm,args --sort=pid | grep -E "sddm|kwin_wayland|plasmashell|ksmserver|pipewire|wireplumber|Xwayland|kworker" | grep -v grep

sec "desktop: compositor"
run --t 20 systemctl status sddm --no-pager -l
run --t 10 sh -c 'journalctl -b -u sddm --no-pager | tail -40'
run --t 10 sh -c 'journalctl -b --no-pager | grep -iE "kwin_wayland|plasmashell|panfrost|egl|gles|opengl" | tail -40'

sec "desktop: kscreen / outputs"
u 20 kscreen-doctor -o 2>&1 | head -40

sec "GPU: EGL (GBM, off-screen, no compositor)"
run --t 30 sh -c 'eglinfo -B -p gbm 2>&1 | head -40'
run --t 30 sh -c 'vulkaninfo --summary 2>&1 | head -30'

sec "GPU: glmark2 on Wayland (through the running compositor)"
u 180 glmark2-es2-wayland --off-screen -s 800x450 -b refract:duration=5 2>&1 | tail -25

sec "desktop: which renderer does KWin composite with"
u 30 sh -c 'gdbus call --session --dest org.kde.KWin --object-path /KWin --method org.kde.KWin.supportInformation 2>/dev/null | tr "," "\n" | grep -iE "OpenGL|renderer|GLSL|Compositing|llvmpipe|Panfrost|vulkan" | head -20'
run --t 10 sh -c 'journalctl -b --no-pager | grep -iE "kwin.*(OpenGL|renderer|compositing)|llvmpipe|panfrost" | tail -20'

sec "screenshot (Wayland)"
if command -v spectacle >/dev/null; then
	u 90 sh -c 'spectacle -b -n -f -o /tmp/l410-firstboot.png; ls -l /tmp/l410-firstboot.png'
	run --t 10 cp /tmp/l410-firstboot.png /var/log/l410-firstboot.png
elif command -v grim >/dev/null; then
	u 90 grim -o eDP-1 /tmp/l410-firstboot.png
	run --t 10 cp /tmp/l410-firstboot.png /var/log/l410-firstboot.png
else
	echo "no spectacle/grim"
fi

sec "audio: ALSA"
run cat /proc/asound/cards
run --t 10 aplay -l
run --t 5 sh -c 'for d in /proc/asound/card*/eld#*; do echo "--- $d"; cat $d; done 2>/dev/null || echo no-eld'
run --t 15 aplay -D plughw:CARD=hi6405,DEV=0 -f S16_LE -r 48000 -c 2 /dev/zero
run --t 15 aplay -D plughw:CARD=hisihdmi,DEV=0 -f S16_LE -r 48000 -c 2 /dev/zero

sec "audio: PipeWire"
run systemctl --user --machine="$USER_@.host" is-active pipewire wireplumber 2>&1
u 20 pactl info
u 20 pactl list cards short
u 20 pactl list sinks short
u 20 wpctl status 2>&1 | head -40

sec "speaker amps: TAS2562 GPIO and register access"
run --t 10 sh -c 'cat /sys/kernel/debug/gpio 2>&1 | grep -idE "gpio-24[0-9]|shutdown|reset" | head'
run --t 10 sh -c 'ls /sys/kernel/debug/regmap/ 2>&1 | head'
for a in 3-004c 3-004e; do
	run --t 10 sh -c "grep -E '^(0[0-9a-f]|[0-7][0-9a-f]):' /sys/kernel/debug/regmap/$a/registers 2>&1 | head -6"
done
echo "--- again with a speaker stream running through PipeWire"
( u 25 speaker-test -D pulse -c 2 -t sine -f 1000 -l 2 >/dev/null 2>&1 & ) 2>/dev/null
sleep 4
for a in 3-004c 3-004e; do
	run --t 10 sh -c "grep -E '^(0[0-9a-f]|[0-7][0-9a-f]):' /sys/kernel/debug/regmap/$a/registers 2>&1 | head -6"
done
run --t 10 sh -c 'cat /sys/kernel/debug/gpio 2>&1 | grep -idE "gpio-24[0-9]" | head'
run --t 10 sh -c 'cd /sys/bus/i2c/devices/3-004c 2>/dev/null && echo 3-004c present; cd /sys/bus/i2c/devices/3-004e 2>/dev/null && echo 3-004e present'
run --t 10 sh -c 'i2cdetect -y -q 3 2>&1 | head -12'

sec "fingerprint"
run ls -l /dev/tc_ns_client /dev/fingerprint
run --t 10 sh -c 'journalctl -b --no-pager | grep -iE "tzdriver|fingerprint|tc_ns|teecd" | tail -30'
run --t 20 systemctl status hwfp_init teecd --no-pager -l
u 20 fprintd-list "$USER_"
run --t 5 sh -c 'ls -l /sys/class/misc/ | grep -i finger'

sec "wifi: Hi110x port"
if [ -n "$(modinfo -n hi110x 2>/dev/null)" ]; then
	run --t 90 modprobe hi110x
	sleep 12
	run --t 10 sh -c 'dmesg | grep -iE "HI110XDBG|hi110x|1103" | tail -40'
	run --t 5 sh -c 'lsmod | grep hi110x'
	run --t 5 sh -c 'ls /sys/bus/pci/devices/'
	run --t 5 sh -c 'lspci -nn'
else
	echo "hi110x module is not installed"
fi

sec "network"
run ip -br addr
run --t 10 nmcli -t device status
run --t 10 nmcli -t connection show --active
run --t 10 sh -c 'iw dev wlan0 link 2>&1 | head -8'
run --t 10 systemctl status ssh --no-pager -l
run --t 10 systemctl status frpc --no-pager -l
run --t 10 sh -c 'journalctl -b -u frpc --no-pager | tail -10'
echo "--- frpc in the foreground (as $USER_)"
$(command -v runuser >/dev/null && echo "runuser -u \"$USER_\" --") timeout 10 /usr/local/bin/frpc -c /etc/frp/frpc.toml 2>&1 | head -20
echo "(rc=$?)"
run --t 5 sh -c 'ls -l /etc/frp/ /usr/local/bin/frpc; head -6 /etc/frp/frpc.toml | sed "s/token.*/token = <redacted>/I"'
run --t 5 ss -ltnp | grep -E ":22 |:6033" 
run --t 5 sh -c 'for i in /sys/class/net/*; do echo "$(basename $i) carrier=$(cat $i/carrier 2>/dev/null) oper=$(cat $i/operstate)"; done'
run --t 10 ethtool enp1s0

sec "kernel messages (errors)"
run --t 10 sh -c 'dmesg | grep -iE "call trace|oops|panic|BUG:|WARNING:|failed|-110|-ENODEV" | tail -60'

sec "tail of dmesg"
run --t 10 sh -c 'dmesg | tail -40'

dmesg > /var/log/l410-firstboot-dmesg.log 2>&1
journalctl -b --no-pager > /var/log/l410-firstboot-journal.log 2>&1
journalctl -b -u sddm --no-pager > /var/log/l410-firstboot-sddm.log 2>&1

if [ -x /opt/l410/tests/quick.sh ]; then
	sec "tests/quick.sh --fast (self-check)"
	arm_deadman
	bash /opt/l410/tests/quick.sh --fast --out /var/log/l410-quick 2>&1
	echo "(rc=$?)"
fi

if [ "$GRAPHICS" = 1 ] && [ -x /opt/l410/tests/graphics.sh ]; then
	sec "tests/graphics.sh (stops sddm, takes the panel over)"
	arm_deadman
	bash /opt/l410/tests/graphics.sh 2>&1
	echo "(rc=$?)"
fi

if [ -x /opt/l410/tests/audio.sh ]; then
	sec "tests/audio.sh (Hi6405 + TAS2562 + mics)"
	arm_deadman
	AUDIO_DUMP_DIR=/var/log/l410-audio bash /opt/l410/tests/audio.sh 2>&1
	echo "(rc=$?)"
fi

sec "done"
echo "===== done $(date -Is)"
sync
if [ "$KEEP" = 1 ]; then
	echo "l410.keep given: staying up"
else
	sleep 2
	echo "l410-firstboot: rebooting" > /dev/kmsg
	systemctl reboot --force
fi
