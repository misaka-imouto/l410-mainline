#!/bin/bash
# test-fingerprint.sh: Diagnostic tool for Huawei Qingyun L410 Fingerprint & TEE
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

echo "=========================================================="
echo " Huawei Qingyun L410 Fingerprint Sensor Diagnostic Test"
echo "=========================================================="

ERR_COUNT=0

# 1. Kernel Devices
info "Checking kernel character devices..."

if [ -c "/dev/tc_ns_client" ]; then
    pass "/dev/tc_ns_client (iTrustee TEE SMC gateway) found: $(ls -l /dev/tc_ns_client)"
else
    fail "/dev/tc_ns_client not found! (Is tzdriver loaded?)"
    ERR_COUNT=$((ERR_COUNT + 1))
fi

if [ -c "/dev/fingerprint" ]; then
    pass "/dev/fingerprint (Huawei platform driver) found: $(ls -l /dev/fingerprint)"
else
    fail "/dev/fingerprint not found! (Is huawei_fingerprint driver loaded?)"
    ERR_COUNT=$((ERR_COUNT + 1))
fi

# 2. Sysfs Attributes
info "Checking sysfs hardware attributes..."
SYSFS_DIR="/sys/class/huawei_fp/fingerprint"
if [ -d "$SYSFS_DIR" ]; then
    pass "Sysfs class directory $SYSFS_DIR exists."
    if [ -f "$SYSFS_DIR/fingerprint_chip_info" ]; then
        info "Chip Info: $(cat $SYSFS_DIR/fingerprint_chip_info 2>/dev/null || true)"
    fi
    if [ -f "$SYSFS_DIR/module_id" ]; then
        info "Module ID: $(cat $SYSFS_DIR/module_id 2>/dev/null || true)"
    fi
    if [ -f "$SYSFS_DIR/irq" ]; then
        info "Sensor IRQ line (live level): $(cat $SYSFS_DIR/irq 2>/dev/null || true)"
    fi
    if [ -f "$SYSFS_DIR/irq_count" ]; then
        info "Sensor interrupts so far: $(cat $SYSFS_DIR/irq_count 2>/dev/null || true)"
    fi
else
    warn "Sysfs directory $SYSFS_DIR not found."
fi

# 3. TrustZone Secure Application
info "Checking TrustZone Trusted Application..."
TA_PATH="/system/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec"
if [ -f "$TA_PATH" ]; then
    pass "Huawei Fingerprint Secure World TA found: $TA_PATH ($(stat -c%s "$TA_PATH") bytes)"
else
    fail "Fingerprint TA not found at $TA_PATH"
    ERR_COUNT=$((ERR_COUNT + 1))
fi

# 4. User Space Daemons
info "Checking user-space daemons..."

if pgrep -x teecd > /dev/null; then
    pass "teecd process is running (PID: $(pgrep -x teecd))"
else
    warn "teecd process is NOT running. Try: sudo systemctl start teecd"
fi

if pgrep -x fingerprint_daemon > /dev/null; then
    pass "fingerprint_daemon is running (PID: $(pgrep -x fingerprint_daemon))"
else
    warn "fingerprint_daemon is NOT running. Try: sudo systemctl start hwfp_init"
fi

# 5. DBus Service
info "Checking DBus biometric service registration..."
if command -v busctl > /dev/null 2>&1; then
    if busctl list 2>/dev/null | grep -q "com.huawei.Fingerprint"; then
        pass "DBus service 'com.huawei.Fingerprint' is active on system bus."
    elif busctl list 2>/dev/null | grep -q "com.deepin.daemon.Authenticate"; then
        pass "DBus service 'com.deepin.daemon.Authenticate' is active on system bus."
    else
        warn "Biometric DBus service not registered on system bus yet."
    fi
fi

# 6. Interrupts check
info "Checking sensor interrupt status in /proc/interrupts..."
if grep -i "fingerprint" /proc/interrupts > /dev/null 2>&1; then
    pass "Kernel IRQ registered:"
    grep -i "fingerprint" /proc/interrupts
else
    info "No /proc/interrupts entry named 'fingerprint' yet."
fi

echo "----------------------------------------------------------"
if [ $ERR_COUNT -eq 0 ]; then
    echo -e "${GREEN}Diagnostic complete: All essential components present.${NC}"
else
    echo -e "${YELLOW}Diagnostic complete with $ERR_COUNT warning(s)/issue(s).${NC}"
fi

# Optional monitor mode
if [ "$1" = "--monitor" ] || [ "$1" = "-m" ]; then
    echo ""
    info "Entering live touch interrupt monitor. Touch the power button fingerprint sensor..."
    info "Press Ctrl+C to stop."
    if [ -f "$SYSFS_DIR/irq_count" ]; then
        OLD_COUNT=0
        while true; do
            CNT=$(cat "$SYSFS_DIR/irq_count" 2>/dev/null || echo 0)
            if [ "$CNT" -ne "$OLD_COUNT" ]; then
                echo -e "${GREEN}[TOUCH DETECTED]${NC} Interrupt count: $CNT ($(date +%T.%3N))"
                OLD_COUNT=$CNT
            fi
            sleep 0.1
        done
    else
        echo "Monitoring /proc/interrupts..."
        while true; do
            grep -i "fingerprint" /proc/interrupts 2>/dev/null || true
            sleep 1
        done
    fi
fi
