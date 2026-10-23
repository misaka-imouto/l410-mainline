#!/bin/bash
# Deploy a kernel bundle built by linux-l410's l410/build.sh to the L410 test root
# (6.18 on /dev/sdd6) and optionally run the quick suite afterwards.
#
#   dev/deploy-remote.sh [BUNDLE] [--host H] [--no-reboot] [--test] [--keep-awake]
#
#   BUNDLE      default ../l410-build/bundle (next to this repo)
#   --host H    ssh host/alias, default $L410_SSH or zhtsg-remote
#   --no-reboot install only
#   --test      after the reboot, run tests/quick.sh and copy the result back
#   --keep-awake
#               disable idle suspend for the desktop user before rebooting.  Do
#               this on a *test rig*: s2idle has no WoWLAN, so an idle machine
#               drops off the network until someone touches the keyboard.
#               See dev/testrig-nosleep.sh (same thing, run locally there).
#
# The L410 needs /usr/local/sbin/l410-setne before a reboot from 6.18: GRUB's
# default entry is the UOS install and the 6.18 root has no grub-editenv.
set -e
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
BUNDLE=$REPO/../l410-build/bundle
HOST=${L410_SSH:-zhtsg-remote}
DO_REBOOT=1 DO_TEST=0 KEEP_AWAKE=0
while [ $# -gt 0 ]; do
	case $1 in
	--host) HOST=$2; shift 2 ;;
	--no-reboot) DO_REBOOT=0; shift ;;
	--test) DO_TEST=1; shift ;;
	--keep-awake) KEEP_AWAKE=1; shift ;;
	-h|--help) sed -n '2,18p' "$0"; exit 0 ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) BUNDLE=$1; shift ;;
	esac
done

for f in Image l410.dtb initrd.img boot.cfg kver modules.tar.gz; do
	[ -e "$BUNDLE/$f" ] || { echo "$BUNDLE/$f missing (run l410/build.sh)" >&2; exit 1; }
done
KVER=$(cat "$BUNDLE/kver")
echo "== bundle $KVER -> $HOST"

# 1. bundle + tests + installer
rsync -az -e ssh "$BUNDLE/" "$HOST:/tmp/l410-bundle/"
rsync -az -e ssh "$REPO/tests/" "$HOST:/tmp/l410-tests/"
scp -q "$REPO/boot/install-kernel.sh" "$HOST:/tmp/install-kernel.sh"

# 2. install kernel and the current test suite
ssh "$HOST" "sudo sh /tmp/install-kernel.sh /tmp/l410-bundle/ | tail -1
	sudo rsync -a --delete /tmp/l410-tests/ /opt/l410/tests/
	sudo chown -R root:root /opt/l410/tests
	echo -n 'quick.sh md5 '; md5sum /opt/l410/tests/quick.sh | cut -d' ' -f1"

if [ "$KEEP_AWAKE" = 1 ]; then
	echo "== disabling idle suspend for the desktop user"
	ssh "$HOST" 'u=$(loginctl list-sessions --no-pager | awk "/seat0/ { print \$3; exit }")
		sudo -u "$u" XDG_RUNTIME_DIR=/run/user/$(id -u "$u") \
			bash /opt/l410/dev/testrig-nosleep.sh 2>/dev/null ||
		sudo cp -a /opt/l410/dev/testrig-nosleep.sh /tmp/ && \
		sudo -u "$u" XDG_RUNTIME_DIR=/run/user/$(id -u "$u") bash /tmp/testrig-nosleep.sh'
fi

[ "$DO_REBOOT" = 1 ] || { echo "== installed, not rebooting"; exit 0; }

# 3. reboot into 6.18 and wait for ssh
ssh "$HOST" 'sudo /usr/local/sbin/l410-setne && sudo reboot' || true
echo -n "== waiting for $HOST"
for _ in $(seq 1 40); do
	sleep 5
	r=$(timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" uname -r 2>/dev/null || true)
	[ -n "$r" ] && { echo; echo "== up: $r"; break; }
	echo -n .
done
[ -n "${r:-}" ] || { echo; echo "!! did not come back (suspended? wrong GRUB entry? check the screen)" >&2; exit 1; }
case "$r" in
"$KVER") ;;
*) echo "!! running $r, expected $KVER (GRUB fell back?)" >&2; exit 1 ;;
esac

# 4. optional quick suite
if [ "$DO_TEST" = 1 ]; then
	echo "== quick suite"
	rc=0
	ssh "$HOST" 'sudo timeout 300 bash /opt/l410/tests/quick.sh --out /var/log/l410-quick/deploy-$(date +%H%M)' | tail -12 || rc=$?
fi

echo "== done"
