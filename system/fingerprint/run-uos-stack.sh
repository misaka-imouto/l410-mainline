#!/bin/sh
# Start the vendor UOS fingerprint stack (teecd + fingerprint_daemon) on the
# 6.18 test root and print what happened.  Run as root on the L410:
#
#   sudo system/fingerprint/run-uos-stack.sh
#
# The files it expects are the ones copied from the UOS root:
#   /vendor/bin/teecd                                  (with /opt/uos-fp/lib libs)
#   /opt/uos-fp/bin/fingerprint_daemon
#   /opt/uos-fp/lib/{libteec.so.1,libfingerprint.so,libhwFingerprint.so,
#                    libssl.so.1.1,libcrypto.so.1.1}
#   /system/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec
set -e
LIB=/opt/uos-fp/lib

if [ "$(id -u)" != 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

modprobe tzdriver 2>/dev/null || true
if [ ! -e /dev/tc_ns_client ]; then
	echo "FAIL: /dev/tc_ns_client missing, tzdriver did not load" >&2
	dmesg | grep -i tzdriver | tail -5 >&2
	exit 1
fi

pkill -9 -x teecd 2>/dev/null || true
pkill -9 -x fingerprint_dae 2>/dev/null || true
sleep 1

LD_LIBRARY_PATH=$LIB setsid nohup /vendor/bin/teecd \
	>/var/tmp/teecd.log 2>&1 </dev/null &
sleep 6
LD_LIBRARY_PATH=$LIB setsid nohup /opt/uos-fp/bin/fingerprint_daemon \
	>/var/tmp/fingerprint-daemon.log 2>&1 </dev/null &
sleep 8

echo "== processes"
ps -ef | grep -E '[t]eecd|[f]ingerprint_dae' || echo "  (none)"
echo
echo "== daemon kernel stack (empty when it is healthy, blocked on SMC otherwise)"
for p in $(pgrep -x fingerprint_dae); do
	cat /proc/$p/stack 2>/dev/null | head -8
done
echo
echo "== dbus"
busctl --system list 2>/dev/null | grep -i huawei || echo "  com.huawei.Fingerprint not on the bus"
echo
echo "== tzdriver log"
dmesg | grep -i tzdriver | tail -15
