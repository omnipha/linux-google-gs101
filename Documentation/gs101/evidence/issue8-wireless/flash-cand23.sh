#!/usr/bin/env bash
# Flash script for Candidate 23: boot_a (cand22) + vendor_boot_a (cand23).
# Target:
#   - boot_a: cand22 boot.img with CONFIG_PCI_EXYNOS=m + CONFIG_DRM_PANFROST=m (sha: 4c172f54...)
#   - vendor_boot_a: cand23 vendor_boot.img with pcie@14520000 + USI16/UART16 DTB (sha: 1d3f3a7e...)
# Rollback reference:
#   - boot_a: cand14 boot.img (sha: 84323d06...)
#   - vendor_boot_a: cand18 vendor_boot.img (sha: 8a6840fb...)
# Guarded by sha256 checksums and cand14-rollback.service check.
# PREPARED ONLY - DO NOT EXECUTE WHILE ROLLBACK UNIT IS ACTIVE OR DEVICE OFFLINE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MB010_ROOT="/home/gregor/phone-second-life-data/mb010"

# Result and evidence directory defaults
EVIDENCE_DIR="${EVIDENCE_DIR:-${RESULT_DIR:-${MB010_ROOT}/flash-scripts}}"
if [ ! -d "${EVIDENCE_DIR}" ] && [ -d "/tmp/opencode/gs101/evidence" ]; then
    EVIDENCE_DIR="/tmp/opencode/gs101/evidence"
fi
RESULT_DIR="${RESULT_DIR:-${EVIDENCE_DIR}}"
mkdir -p "${RESULT_DIR}"

TS=$(date +%Y%m%d-%H%M%S)
LOG="${RESULT_DIR}/flash-cand23-${TS}.log"
RESULT_JSON="${RESULT_DIR}/flash-cand23-${TS}.json"

# Image path defaults with fallback to /tmp
BOOT_IMG="${BOOT_IMG:-${MB010_ROOT}/cand-images/cand22-boot.img}"
if [ ! -f "${BOOT_IMG}" ] && [ -f "/tmp/opencode/gs101/cand22/boot.img" ]; then
    BOOT_IMG="/tmp/opencode/gs101/cand22/boot.img"
fi

VENDOR_BOOT_IMG="${VENDOR_BOOT_IMG:-${MB010_ROOT}/cand-images/cand23-vendor_boot.img}"
if [ ! -f "${VENDOR_BOOT_IMG}" ] && [ -f "/tmp/opencode/gs101/cand23/vendor_boot.img" ]; then
    VENDOR_BOOT_IMG="/tmp/opencode/gs101/cand23/vendor_boot.img"
fi

ROLLBACK_BOOT="${ROLLBACK_BOOT:-${MB010_ROOT}/cand-images/cand14-boot-rollback.img}"
if [ ! -f "${ROLLBACK_BOOT}" ] && [ -f "/tmp/opencode/gs101/cand14/boot.img" ]; then
    ROLLBACK_BOOT="/tmp/opencode/gs101/cand14/boot.img"
fi

ROLLBACK_VENDOR="${ROLLBACK_VENDOR:-${MB010_ROOT}/cand-images/cand18-vendor_boot-rollback.img}"
if [ ! -f "${ROLLBACK_VENDOR}" ] && [ -f "/tmp/opencode/gs101/cand18/vendor_boot.img" ]; then
    ROLLBACK_VENDOR="/tmp/opencode/gs101/cand18/vendor_boot.img"
fi

KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-${MB010_ROOT}/deploy-harden/ssh/known_hosts}"
if [ ! -f "${KNOWN_HOSTS_FILE}" ] && [ -f "/tmp/opencode/gs101/issue4/known_hosts" ]; then
    KNOWN_HOSTS_FILE="/tmp/opencode/gs101/issue4/known_hosts"
fi

SSH_HELPER="${SSH_HELPER:-${MB010_ROOT}/flash-scripts/sshc.sh}"
if [ ! -f "${SSH_HELPER}" ] && [ -f "/tmp/opencode/gs101/issue4/sshc.sh" ]; then
    SSH_HELPER="/tmp/opencode/gs101/issue4/sshc.sh"
fi

EXPECT_CAND22_BOOT="4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9"
EXPECT_CAND23_VENDOR="1d3f3a7e2fa2759d656651673b2ea0c84d0f92c53ff9d3a2e4766d19f0424c9d"
EXPECT_ROLLBACK_BOOT="84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36"
EXPECT_ROLLBACK_VENDOR="8a6840fbbc2035862a46123f5b25539d1085903a16d38a8904bb2966142ac818"

exec > >(tee -a "$LOG") 2>&1

echo "=== FLASH cand23 start at $(date -Iseconds) ==="

# Check unit status guard: cand14-rollback.service must NOT be active
if systemctl --user is-active cand14-rollback.service >/dev/null 2>&1; then
    echo "FATAL: cand14-rollback.service is active! Multiple flash writers forbidden."
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 3, "target": "boot_a+vendor_boot_a", "error": "cand14-rollback.service active"}
EOF
    exit 3
fi

ACT_CAND22_BOOT=$(sha256sum "$BOOT_IMG" 2>/dev/null | awk '{print $1}')
if [ "$ACT_CAND22_BOOT" != "$EXPECT_CAND22_BOOT" ]; then
    echo "FATAL: cand22 boot.img hash mismatch: '$ACT_CAND22_BOOT' != '$EXPECT_CAND22_BOOT'"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 1, "target": "boot_a+vendor_boot_a", "error": "cand22 boot sha256 mismatch", "actual_hash": "$ACT_CAND22_BOOT"}
EOF
    exit 1
fi

ACT_CAND23_VENDOR=$(sha256sum "$VENDOR_BOOT_IMG" 2>/dev/null | awk '{print $1}')
if [ "$ACT_CAND23_VENDOR" != "$EXPECT_CAND23_VENDOR" ]; then
    echo "FATAL: cand23 vendor_boot.img hash mismatch: '$ACT_CAND23_VENDOR' != '$EXPECT_CAND23_VENDOR'"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 1, "target": "boot_a+vendor_boot_a", "error": "cand23 vendor sha256 mismatch", "actual_hash": "$ACT_CAND23_VENDOR"}
EOF
    exit 1
fi

ACT_ROLLBACK_BOOT=$(sha256sum "$ROLLBACK_BOOT" 2>/dev/null | awk '{print $1}')
if [ "$ACT_ROLLBACK_BOOT" != "$EXPECT_ROLLBACK_BOOT" ]; then
    echo "FATAL: rollback cand14 boot.img hash mismatch: '$ACT_ROLLBACK_BOOT' != '$EXPECT_ROLLBACK_BOOT'"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 1, "target": "boot_a+vendor_boot_a", "error": "cand14 rollback boot sha256 mismatch", "actual_hash": "$ACT_ROLLBACK_BOOT"}
EOF
    exit 1
fi

ACT_ROLLBACK_VENDOR=$(sha256sum "$ROLLBACK_VENDOR" 2>/dev/null | awk '{print $1}')
if [ "$ACT_ROLLBACK_VENDOR" != "$EXPECT_ROLLBACK_VENDOR" ]; then
    echo "FATAL: rollback cand18 vendor_boot.img hash mismatch: '$ACT_ROLLBACK_VENDOR' != '$EXPECT_ROLLBACK_VENDOR'"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 1, "target": "boot_a+vendor_boot_a", "error": "cand18 rollback vendor sha256 mismatch", "actual_hash": "$ACT_ROLLBACK_VENDOR"}
EOF
    exit 1
fi

echo "--- hashes verified ---"
echo "cand22 boot:      $ACT_CAND22_BOOT  $BOOT_IMG"
echo "cand23 vendor:    $ACT_CAND23_VENDOR  $VENDOR_BOOT_IMG"
echo "rollback boot:    $ACT_ROLLBACK_BOOT  $ROLLBACK_BOOT"
echo "rollback vendor:  $ACT_ROLLBACK_VENDOR  $ROLLBACK_VENDOR"

echo "--- checking SSH connectivity to reboot to bootloader ---"
if ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
       -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=2 \
       user@172.16.42.1 'echo ONLINE' >/dev/null 2>&1; then
    echo "SSH reachable: requesting reboot to bootloader..."
    if [ -x "${SSH_HELPER}" ]; then
        "${SSH_HELPER}" 'sudo reboot bootloader' || true
    else
        ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
            -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=2 \
            user@172.16.42.1 'sudo reboot bootloader' || true
    fi
else
    echo "SSH not reachable (device may already be in fastboot mode), skipping reboot command."
fi

echo "Waiting for fastboot device (single shot, max 30s)..."
DEV=""
for i in $(seq 1 30); do
    DEV=$(fastboot devices | head -n1)
    if [ -n "$DEV" ]; then
        echo "Found fastboot device: $DEV"
        break
    fi
    sleep 1
done

if [ -z "$DEV" ]; then
    echo "ERROR: fastboot device not found after 30s!"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 2, "target": "boot_a+vendor_boot_a", "error": "fastboot device timeout"}
EOF
    exit 2
fi

echo "--- set_active a ---"
fastboot set_active a || true

echo "--- flash boot_a = cand22 ---"
fastboot flash boot_a "$BOOT_IMG"
RC_BOOT=$?

if [ $RC_BOOT -ne 0 ]; then
    echo "ERROR: fastboot flash boot_a failed with code $RC_BOOT"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": $RC_BOOT, "target": "boot_a", "error": "flash boot_a failed"}
EOF
    exit $RC_BOOT
fi

echo "--- flash vendor_boot_a = cand23 ---"
fastboot flash vendor_boot_a "$VENDOR_BOOT_IMG"
RC_VENDOR=$?

if [ $RC_VENDOR -ne 0 ]; then
    echo "ERROR: fastboot flash vendor_boot_a failed with code $RC_VENDOR"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": $RC_VENDOR, "target": "vendor_boot_a", "error": "flash vendor_boot_a failed"}
EOF
    exit $RC_VENDOR
fi

echo "--- reboot ---"
fastboot reboot || true

cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 0, "target": "boot_a+vendor_boot_a", "cand22_boot_hash": "$ACT_CAND22_BOOT", "cand23_vendor_hash": "$ACT_CAND23_VENDOR", "device": "$DEV", "status": "flashed and rebooted"}
EOF

echo "=== FLASH cand23 complete flash_rc=0 at $(date -Iseconds) ==="
exit 0
