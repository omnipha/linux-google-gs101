#!/usr/bin/env bash
# install-wlan.sh - Sideload and activate BCM4389 Wi-Fi & Bluetooth bundle on Google Tensor GS101 (raven)
# NOTE: DO NOT EXECUTE WHILE DEVICE IS OFFLINE OR WITHOUT OPERATOR AUTHORIZATION.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_HOST="${TARGET_HOST:-172.16.42.1}"
TARGET_USER="${TARGET_USER:-user}"
KERNEL_VER="7.3.0-rc6-gs101"
SSH_OPTS="-i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3"

echo "=== Google Tensor GS101 (raven) BCM4389 WLAN & Bluetooth Deployment ==="
echo "Target: ${TARGET_USER}@${TARGET_HOST}"
echo "Kernel: ${KERNEL_VER}"
echo "Source: ${SCRIPT_DIR}"

# Precondition check: Device must be reachable over SSH
if ! ping -c 1 -W 2 "${TARGET_HOST}" >/dev/null 2>&1; then
    echo "ERROR: Target ${TARGET_HOST} is unreachable (ping failed). Physical recovery and SSH up are required." >&2
    exit 1
fi

if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "true" 2>/dev/null; then
    echo "ERROR: Target ${TARGET_HOST} SSH connection failed. Check host availability and credentials." >&2
    exit 1
fi

echo "[1/4] Copying kernel modules to target /lib/modules/${KERNEL_VER}/extra/ ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo mkdir -p /lib/modules/${KERNEL_VER}/extra"
rsync -avz -e "ssh $SSH_OPTS" "${SCRIPT_DIR}/lib/modules/${KERNEL_VER}/extra/" "${TARGET_USER}@${TARGET_HOST}:/tmp/wlan-extra-mods/"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo cp -p /tmp/wlan-extra-mods/*.ko /lib/modules/${KERNEL_VER}/extra/ && sudo rm -rf /tmp/wlan-extra-mods"

echo "[2/4] Copying firmware blobs to target /lib/firmware/ ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo mkdir -p /lib/firmware/brcm"
rsync -avz -e "ssh $SSH_OPTS" "${SCRIPT_DIR}/lib/firmware/" "${TARGET_USER}@${TARGET_HOST}:/tmp/wlan-fw/"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo cp -rp /tmp/wlan-fw/* /lib/firmware/ && sudo rm -rf /tmp/wlan-fw && sudo chown -R root:root /lib/firmware/bcmdhd* /lib/firmware/fw_bcmdhd* /lib/firmware/google_wifi* /lib/firmware/brcm && sudo chmod 0644 /lib/firmware/bcmdhd* /lib/firmware/fw_bcmdhd* /lib/firmware/google_wifi* /lib/firmware/brcm/*"

echo "[3/4] Updating target module dependency tree (depmod -a) ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo depmod -a ${KERNEL_VER}"

echo "[4/4] Executing controlled module loading sequence ..."

# --- Step A: PCIe Controller Host Driver ---
# RATIONALE: CONFIG_PCI_EXYNOS is built as =m (modular) to prevent early-boot panics (cand13/cand19).
# PCIe RC1 (pcie@14520000) must initialize and establish an L0 link before bcmdhd can probe.
echo "--> Loading pci-exynos (PCIe RC1 root complex) ..."
if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo modprobe pci-exynos"; then
    echo "WARNING: Failed to load pci-exynos. Check dmesg for PCIe RC initialization errors." >&2
fi
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "dmesg | grep -iE 'pcie|exynos.*pci' | tail -n 20 || true"

# --- Step B: Wireless Subsystem Core ---
echo "--> Loading rfkill and cfg80211 ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo modprobe rfkill && sudo modprobe cfg80211"

# --- Step C: Broadcom BCM4389 FullMAC Wi-Fi Driver ---
# Standard request_firmware() resolves /lib/firmware/fw_bcmdhd.bin and /lib/firmware/bcmdhd.cal.
echo "--> Loading bcmdhd (Broadcom BCM4389 Wi-Fi) ..."
if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo modprobe bcmdhd"; then
    echo "WARNING: Failed to load bcmdhd. Verify PCIe link state and firmware presence." >&2
fi

# --- Step D: Bluetooth Subsystem & Serdev HCI Driver ---
# cand23 DTB provides serial@175b0000 with child bluetooth node. hci_uart binds via serdev.
echo "--> Loading bluetooth and hci_uart ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo modprobe bluetooth && sudo modprobe hci_uart"

echo "=== Deployment Finished. Verifying Target Hardware Status ==="

# Verification Criteria:
# 1. WLAN Success: PCIe link present, wlan0 interface created, iw dev responsive
echo "--- 1. WLAN Status ---"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
    echo "PCI devices:"; lspci -nn -k 2>/dev/null || true
    echo "Network interfaces:"; ip link show wlan0 2>/dev/null || ip link show
    echo "Wireless devices:"; iw dev 2>/dev/null || true
'

# 2. Bluetooth Success: /sys/class/bluetooth/hci0 exists, hciconfig hci0 up succeeds
echo "--- 2. Bluetooth Status ---"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
    if [ -d /sys/class/bluetooth/hci0 ]; then
        echo "SUCCESS: /sys/class/bluetooth/hci0 detected."
        sudo hciconfig hci0 up 2>/dev/null && hciconfig -a || true
    else
        echo "PENDING: /sys/class/bluetooth/hci0 not yet visible. Check dmesg serdev logs."
        dmesg | grep -iE "bluetooth|hci|serdev" | tail -n 20 || true
    fi
'

echo "Deployment and verification check complete."
