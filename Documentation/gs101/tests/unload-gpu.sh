#!/usr/bin/env bash
# unload-gpu.sh - Unload Panfrost GPU modules and remove reboot persistence
set -euo pipefail

TARGET_HOST="${TARGET_HOST:-172.16.42.1}"
TARGET_USER="${TARGET_USER:-user}"
SSH_OPTS="-i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3"

echo "=== Unloading Panfrost GPU acceleration on ${TARGET_USER}@${TARGET_HOST} ==="

if ping -c 1 -W 2 "${TARGET_HOST}" >/dev/null 2>&1; then
    echo "1. Removing /etc/modules-load.d/panfrost.conf (reboot persistence) ..."
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo rm -f /etc/modules-load.d/panfrost.conf"

    echo "2. Unloading panfrost ..."
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo rmmod panfrost 2>/dev/null || true"

    echo "3. Unloading gpu-sched ..."
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo rmmod gpu_sched 2>/dev/null || true"

    echo "4. Verifying unload state ..."
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "lsmod | grep -E '(panfrost|gpu_sched)' || echo 'Panfrost and gpu-sched successfully unloaded.'"
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "ls -la /dev/dri 2>/dev/null || true"
else
    echo "Host ${TARGET_HOST} not reachable over network. If running locally on target:"
    echo "  sudo rm -f /etc/modules-load.d/panfrost.conf"
    echo "  sudo rmmod panfrost gpu_sched"
fi
