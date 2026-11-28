#!/usr/bin/env bash
# install-gpu.sh - Sideload and activate Panfrost GPU acceleration on Google Tensor GS101 (raven)
# NOTE: DO NOT EXECUTE WHILE DEVICE IS OFFLINE OR WITHOUT OPERATOR AUTHORIZATION.
set -euo pipefail

TARGET_HOST="${TARGET_HOST:-172.16.42.1}"
TARGET_USER="${TARGET_USER:-user}"
KERNEL_VER="7.3.0-rc6-gs101"

# Permanent host defaults with fallbacks
CAND22_MOD_DIR="${CAND22_MOD_DIR:-/home/gregor/phone-second-life-data/mb010/deploy-harden/gpu-modules}"
if [ ! -d "${CAND22_MOD_DIR}" ] && [ -d "/tmp/opencode/gs101/cand22/modules" ]; then
    CAND22_MOD_DIR="/tmp/opencode/gs101/cand22/modules"
fi

KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-/home/gregor/phone-second-life-data/mb010/deploy-harden/ssh/known_hosts}"
if [ ! -f "${KNOWN_HOSTS_FILE}" ] && [ -f "/tmp/opencode/gs101/issue4/known_hosts" ]; then
    KNOWN_HOSTS_FILE="/tmp/opencode/gs101/issue4/known_hosts"
fi

SSH_OPTS="-i ~/.ssh/id_ed25519 -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3"

echo "=== Google Tensor GS101 (raven) Panfrost GPU Acceleration Deployment ==="
echo "Target: ${TARGET_USER}@${TARGET_HOST}"
echo "Kernel: ${KERNEL_VER}"
echo "Modules source: ${CAND22_MOD_DIR}"

# Precondition check: Device must be reachable over SSH
if ! ping -c 1 -W 2 "${TARGET_HOST}" >/dev/null 2>&1; then
    echo "ERROR: Target ${TARGET_HOST} is unreachable (ping failed). Physical recovery and SSH up are required." >&2
    exit 1
fi

if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "true" 2>/dev/null; then
    echo "ERROR: Target ${TARGET_HOST} SSH connection failed. Check host availability and credentials." >&2
    exit 1
fi

echo "--- Status VORHER ---"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
    echo "1. lsmod panfrost:"
    lsmod | grep -E "(panfrost|gpu_sched)" || echo "  (no panfrost/gpu-sched module currently loaded)"
    echo "2. Check /lib/modules/'"${KERNEL_VER}"'/extra/panfrost.ko:"
    if [ -f "/lib/modules/'"${KERNEL_VER}"'/extra/panfrost.ko" ]; then
        ls -l "/lib/modules/'"${KERNEL_VER}"'/extra/panfrost.ko"
    else
        echo "  (not yet present in /lib/modules/'"${KERNEL_VER}"'/extra/)"
    fi
    echo "3. DRM devices in /dev/dri:"
    ls -la /dev/dri 2>/dev/null || echo "  (/dev/dri does not exist)"
'

echo "[1/4] Copying GPU modules (gpu-sched.ko, panfrost.ko) to target /lib/modules/${KERNEL_VER}/extra/ ..."
if [ ! -f "${CAND22_MOD_DIR}/gpu-sched.ko" ] || [ ! -f "${CAND22_MOD_DIR}/panfrost.ko" ]; then
    echo "ERROR: Source modules not found in ${CAND22_MOD_DIR}" >&2
    exit 1
fi

ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo mkdir -p /lib/modules/${KERNEL_VER}/extra"
rsync -avz -e "ssh $SSH_OPTS" "${CAND22_MOD_DIR}/gpu-sched.ko" "${CAND22_MOD_DIR}/panfrost.ko" "${TARGET_USER}@${TARGET_HOST}:/tmp/gpu-mods/"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo cp -p /tmp/gpu-mods/*.ko /lib/modules/${KERNEL_VER}/extra/ && sudo rm -rf /tmp/gpu-mods && sudo chmod 0644 /lib/modules/${KERNEL_VER}/extra/gpu-sched.ko /lib/modules/${KERNEL_VER}/extra/panfrost.ko"

echo "[2/4] Updating module dependency tree (depmod -a) ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo depmod -a ${KERNEL_VER}"

echo "[3/4] Loading panfrost via modprobe (gpu-sched resolved by depmod) ..."
if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo modprobe panfrost"; then
    echo "WARNING: Failed to load panfrost via modprobe." >&2
    echo "Fallback: Manual insmod from /tmp (temporary testing):" >&2
    echo "  sudo insmod /tmp/gpu-sched.ko && sudo insmod /tmp/panfrost.ko" >&2
fi

echo "[4/4] Configuring reboot persistence in /etc/modules-load.d/panfrost.conf ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
    sudo mkdir -p /etc/modules-load.d
    printf "gpu-sched\npanfrost\n" | sudo tee /etc/modules-load.d/panfrost.conf >/dev/null
    sudo chmod 0644 /etc/modules-load.d/panfrost.conf
'

echo "=== Verifying GPU Acceleration Status ==="
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
    echo "--- A. Loaded Modules ---"
    lsmod | grep -E "(panfrost|gpu_sched)" || { echo "ERROR: panfrost/gpu-sched not in lsmod"; exit 1; }

    echo "--- B. DRM Node renderD128 ---"
    if [ -e /dev/dri/renderD128 ]; then
        echo "SUCCESS: /dev/dri/renderD128 is present."
        ls -la /dev/dri/
    else
        echo "ERROR: /dev/dri/renderD128 not found." >&2
        exit 1
    fi

    echo "--- C. dmesg Panfrost GPU Initialization & Sanity Check ---"
    dmesg_gpu=$(dmesg | grep -i panfrost || true)
    echo "${dmesg_gpu}"
    if echo "${dmesg_gpu}" | grep -q "mali-unknown"; then
        echo "ERROR: GPU model reported as mali-unknown!" >&2
        exit 1
    elif echo "${dmesg_gpu}" | grep -iE "(oops|kernel BUG|panic)"; then
        echo "ERROR: Kernel oops/panic detected during panfrost load!" >&2
        exit 1
    elif echo "${dmesg_gpu}" | grep -qi "mali"; then
        echo "SUCCESS: Valid Mali GPU model identified by panfrost."
    fi

    echo "--- D. Persistence Configuration ---"
    cat /etc/modules-load.d/panfrost.conf
'
echo "Panfrost GPU acceleration deployment and verification complete."
