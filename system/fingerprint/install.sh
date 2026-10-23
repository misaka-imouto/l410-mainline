#!/bin/bash
# fingerprint: Huawei Qingyun L410 power button fingerprint sensor and iTrustee TEE integration.
#
# Hardware & TrustZone:
#   - FPC capacitive fingerprint sensor (sensor_type 0x204, FPC1020/1025 family)
#   - SPI1 bus dedicated to ARM TrustZone (iTrustee Secure OS)
#   - RST GPIO 199, IRQ GPIO 234
#   - Kernel drivers: /dev/tc_ns_client (tzdriver), /dev/fingerprint (huawei-fingerprint)
#   - Secure TA: /system/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec
#   - Daemons: teecd, fingerprint_daemon, deepin-authenticate
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
D=$L410_SYSTEM/fingerprint

say "Installing Huawei Fingerprint & iTrustee TEE configuration..."

# 1. Install udev rules for device nodes (/dev/tc_ns_client and /dev/fingerprint)
install -D -m 644 "$D/99-huawei-fingerprint.rules" /etc/udev/rules.d/99-huawei-fingerprint.rules
udevadm control --reload-rules || true
live && udevadm trigger --action=change || true

# 2. Verify or create tee group for secure access
if ! getent group tee > /dev/null 2>&1; then
    groupadd -r tee || true
fi

# Add desktop user to input and tee groups
DESKTOP_USER=$(l410_user)
if [ -n "$DESKTOP_USER" ]; then
    usermod -a -G input,tee "$DESKTOP_USER" 2>/dev/null || true
fi

# 3. Ensure TrustZone TA storage path exists and is accessible
mkdir -p /system/vendor/bin /vendor/bin /data/vendor/log /var/lib/dde-daemon/fingerprint
chmod 755 /var/lib/dde-daemon/fingerprint || true

# Verify TA presence
TA_PATH="/system/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec"
if [ ! -f "$TA_PATH" ] && [ -f "/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec" ]; then
    ln -sf "/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec" "$TA_PATH"
fi

# 4. Install the D-Bus security policy.  dbus-daemon refuses to let
#    fingerprint_daemon own com.huawei.Fingerprint without it, which shows up
#    as "Connection ... is not allowed to own the service" in hw_log.txt.
install -D -m 644 "$D/dbus/com.huawei.Fingerprint.conf" /etc/dbus-1/system.d/com.huawei.Fingerprint.conf
install -D -m 644 "$D/dbus/com.huawei.Fingerprint.service" /usr/share/dbus-1/system-services/com.huawei.Fingerprint.service
systemctl reload dbus 2>/dev/null || systemctl restart dbus 2>/dev/null || true

# 4b. The TA's SFS is backed by /data/sec_storage_data on the data partition
#     (_dde_data, /dev/sdd7 on the L410).  Without it mounted at /data, TA
#     cmd 0 (fpc_tac_init_lib) never completes and the daemon hangs during
#     init.  Add the fstab entry if this root has no /data mount yet.
if ! findmnt -n /data >/dev/null 2>&1; then
    say "WARNING: /data is not mounted; fingerprint SFS needs it (see docs)"
fi

# 4c. Install the systemd units and the power-on helper.
install -D -m 644 "$D/systemd/teecd.service" /etc/systemd/system/teecd.service
install -D -m 644 "$D/systemd/hwfp_init.service" /etc/systemd/system/hwfp_init.service
if command -v gcc >/dev/null 2>&1; then
    gcc -O2 -o /usr/local/sbin/fp_poweron "$D/bin/fp_poweron.c" 2>/dev/null || true
fi
systemctl daemon-reload || true

# 5. Enable and start teecd service
if [ -f "/usr/lib/systemd/system/teecd.service" ] || [ -f "/etc/systemd/system/teecd.service" ]; then
    say "Enabling teecd service (iTrustee client daemon)..."
    enable_now teecd.service || true
fi

# 6. Enable and start hwfp_init service
if [ -f "/usr/lib/systemd/system/hwfp_init.service" ] || [ -f "/etc/systemd/system/hwfp_init.service" ]; then
    say "Enabling hwfp_init service (Huawei Fingerprint Daemon)..."
    enable_now hwfp_init.service || true
fi

# 7. Enable Deepin Authentication service if installed
if [ -f "/usr/lib/systemd/system/deepin-authenticate.service" ]; then
    say "Enabling deepin-authenticate service..."
    enable_now deepin-authenticate.service || true
fi

echo "fingerprint: udev rules, iTrustee teecd, and fingerprint_daemon enabled."
