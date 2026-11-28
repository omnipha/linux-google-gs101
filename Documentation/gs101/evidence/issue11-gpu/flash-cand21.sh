#!/usr/bin/env bash
# Flash script for Candidate 21: boot_a (cand20) + vendor_boot_a (cand21).
# Target:
#   - boot_a: cand20 boot.img with CONFIG_DRM_PANFROST=m (sha: 4c172f54...)
#   - vendor_boot_a: cand21 vendor_boot.img with corrected USI16/UART16 DTB (sha: 43d5252a...)
# Rollback reference:
#   - boot_a: cand14 boot.img (sha: 84323d06...)
#   - vendor_boot_a: cand18 vendor_boot.img (sha: 8a6840fb...)
# Guarded by sha256 checksums. Outputs result JSON.
# PREPARED ONLY - DO NOT EXECUTE WHILE ROLLBACK UNIT IS ACTIVE OR DEVICE OFFLINE.
set -u

TS=$(date +%Y%m%d-%H%M%S)
LOG="/tmp/opencode/gs101/evidence/flash-cand21-${TS}.log"
RESULT_JSON="/tmp/opencode/gs101/evidence/flash-cand21-${TS}.json"

BOOT_IMG="/tmp/opencode/gs101/cand20/boot.img"
VENDOR_BOOT_IMG="/tmp/opencode/gs101/cand21/vendor_boot.img"
ROLLBACK_BOOT="/tmp/opencode/gs101/cand14/boot.img"
ROLLBACK_VENDOR="/tmp/opencode/gs101/cand18/vendor_boot.img"

EXPECT_CAND20_BOOT="4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9"
EXPECT_CAND21_VENDOR="43d5252a016b6b77fa4ed6164da097e84c0c2ce23eb9a9cd640e00209599daf4"
EXPECT_ROLLBACK_BOOT="84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36"
EXPECT_ROLLBACK_VENDOR="8a6840fbbc2035862a46123f5b25539d1085903a16d38a8904bb2966142ac818"

mkdir -p /tmp/opencode/gs101/evidence
exec > >(tee -a "$LOG") 2>&1

echo "=== FLASH cand21 start at $(date -Iseconds) ==="

# Check unit status guard: cand14-rollback.service must NOT be active
if systemctl --user is-active cand14-rollback.service >/dev/null 2>&1; then
    echo "FATAL: cand14-rollback.service is active! Multiple flash writers forbidden."
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 3, "target": "boot_a+vendor_boot_a", "error": "cand14-rollback.service active"}
EOF
    exit 3
fi

ACT_CAND20_BOOT=$(sha256sum "$BOOT_IMG" 2>/dev/null | awk '{print $1}')
if [ "$ACT_CAND20_BOOT" != "$EXPECT_CAND20_BOOT" ]; then
    echo "FATAL: cand20 boot.img hash mismatch: '$ACT_CAND20_BOOT' != '$EXPECT_CAND20_BOOT'"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 1, "target": "boot_a+vendor_boot_a", "error": "cand20 boot sha256 mismatch", "actual_hash": "$ACT_CAND20_BOOT"}
EOF
    exit 1
fi

ACT_CAND21_VENDOR=$(sha256sum "$VENDOR_BOOT_IMG" 2>/dev/null | awk '{print $1}')
if [ "$ACT_CAND21_VENDOR" != "$EXPECT_CAND21_VENDOR" ]; then
    echo "FATAL: cand21 vendor_boot.img hash mismatch: '$ACT_CAND21_VENDOR' != '$EXPECT_CAND21_VENDOR'"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": 1, "target": "boot_a+vendor_boot_a", "error": "cand21 vendor sha256 mismatch", "actual_hash": "$ACT_CAND21_VENDOR"}
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
echo "cand20 boot:      $ACT_CAND20_BOOT  $BOOT_IMG"
echo "cand21 vendor:    $ACT_CAND21_VENDOR  $VENDOR_BOOT_IMG"
echo "rollback boot:    $ACT_ROLLBACK_BOOT  $ROLLBACK_BOOT"
echo "rollback vendor:  $ACT_ROLLBACK_VENDOR  $ROLLBACK_VENDOR"

echo "--- checking SSH connectivity to reboot to bootloader ---"
if ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
       -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=2 \
       user@172.16.42.1 'echo ONLINE' >/dev/null 2>&1; then
    echo "SSH reachable: requesting reboot to bootloader..."
    /tmp/opencode/gs101/issue4/sshc.sh 'sudo reboot bootloader' || true
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

echo "--- flash boot_a = cand20 ---"
fastboot flash boot_a "$BOOT_IMG"
RC_BOOT=$?

if [ $RC_BOOT -ne 0 ]; then
    echo "ERROR: fastboot flash boot_a failed with code $RC_BOOT"
    cat <<EOF > "$RESULT_JSON"
{"timestamp": "$(date -Iseconds)", "flash_rc": $RC_BOOT, "target": "boot_a", "error": "flash boot_a failed"}
EOF
    exit $RC_BOOT
fi

echo "--- flash vendor_boot_a = cand21 ---"
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
{"timestamp": "$(date -Iseconds)", "flash_rc": 0, "target": "boot_a+vendor_boot_a", "cand20_boot_hash": "$ACT_CAND20_BOOT", "cand21_vendor_hash": "$ACT_CAND21_VENDOR", "device": "$DEV", "status": "flashed and rebooted"}
EOF

echo "=== FLASH cand21 complete flash_rc=0 at $(date -Iseconds) ==="
exit 0
