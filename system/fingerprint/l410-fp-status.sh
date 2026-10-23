#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# l410-fp-status.sh - health check for the L410 fingerprint stack.
#
#   sudo system/fingerprint/l410-fp-status.sh
#
# Prints one line per layer (TEE driver, notify page, agents, vendor daemon,
# template database, fprintd shim, PAM) so a regression is visible at a glance.
set -u

ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
info() { printf '  [info] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== L410 fingerprint status =="

# --- kernel / TEE -----------------------------------------------------
if [ -e /dev/tc_ns_client ]; then
	ok "/dev/tc_ns_client present"
else
	bad "/dev/tc_ns_client missing (tzdriver not loaded?)"
fi

if grep -q tc_ns_client /proc/interrupts 2>/dev/null; then
	ok "TEE notify IRQ registered ($(awk '/tc_ns_client/{print $NF}' /proc/interrupts | head -1))"
else
	bad "TEE notify IRQ missing: tz_spi_init() did not run (kirin990_notify must be Y)."
	info "without it every long TA command falls back to 4ms-per-round spinning"
fi

if [ -r /sys/module/tzdriver/parameters/kirin990_notify ]; then
	info "kirin990_notify=$(cat /sys/module/tzdriver/parameters/kirin990_notify)" \
	     "agent_register_user=$(cat /sys/module/tzdriver/parameters/agent_register_user)"
fi

# --- TEE agents (teecd's fs/misc/load agents) -------------------------
if have journalctl; then
	agents=$(journalctl -k -b 2>/dev/null | grep -c "registered with tee")
	misses=$(journalctl -k -b 2>/dev/null | grep -c "not exist")
	[ "${agents:-0}" -ge 3 ] && ok "agents registered: $agents" \
		|| bad "agents registered: ${agents:-0} (expected >= 3; is teecd running?)"
	[ "${misses:-0}" -eq 0 ] && ok "agent lookups: no 'not exist' errors" \
		|| bad "agent lookups failing ($misses 'not exist' lines): nsid mismatch?"
fi

# --- services ---------------------------------------------------------
for svc in teecd hwfp_init l410-fprintd-shim; do
	if systemctl is-active --quiet "$svc" 2>/dev/null; then
		ok "service $svc active"
	else
		bad "service $svc not active (systemctl start $svc)"
	fi
done

# --- data partition + SFS --------------------------------------------
if findmnt -n /data >/dev/null 2>&1; then
	ok "/data mounted ($(findmnt -n -o SOURCE /data))"
else
	bad "/data not mounted: the TA's SFS has no backing store, cmd 0 will crawl"
fi

sfs=/data/sec_storage_data/fp/data/fpc
if [ -d "$sfs" ]; then
	db=$(find "$sfs" -maxdepth 1 -type f -size +10k ! -name '*.bk' | head -1)
	if [ -n "$db" ]; then
		ok "template db: $(basename "$db") ($(stat -c %s "$db") bytes)"
	else
		info "no template database yet (nothing enrolled)"
	fi
else
	bad "$sfs missing (secure storage not initialised)"
fi

# --- fprintd interface ------------------------------------------------
if have fprintd-list; then
	user=$(id -un)
	out=$(fprintd-list "$user" 2>&1)
	case "$out" in
	*found\ 1\ devices*) ok "fprintd sees 1 device" ;;
	*No\ devices*|*manager*|*timeout*) bad "fprintd cannot reach the shim: $out" ;;
	*) ok "fprintd responded" ;;
	esac
	printf '%s\n' "$out" | grep -E '^\s+- #' | sed 's/^/  [info]   /'
fi

# --- PAM --------------------------------------------------------------
grep -q pam_fprintd /etc/pam.d/sudo 2>/dev/null \
	&& ok "sudo can use the fingerprint" \
	|| info "sudo has no pam_fprintd line"
if grep -q pam_fprintd /etc/pam.d/common-auth 2>/dev/null; then
	bad "common-auth contains pam_fprintd: that breaks the KDE lock screen"
else
	ok "common-auth is password-only (as intended)"
fi
grep -q "pam_fprintd" /usr/lib/pam.d/kde-fingerprint 2>/dev/null \
	&& ok "lock screen stack (/usr/lib/pam.d/kde-fingerprint) has pam_fprintd" \
	|| bad "lock screen stack lost pam_fprintd"

# --- misc -------------------------------------------------------------
[ -r /sys/kernel/l410_deadman/timeout ] && \
	info "l410_deadman timeout=$(cat /sys/kernel/l410_deadman/timeout)" \
	     "(should be 0; l410-firstboot arms it and can panic the box)"

echo "== done =="
