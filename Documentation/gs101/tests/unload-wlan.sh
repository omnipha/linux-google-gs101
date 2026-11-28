#!/usr/bin/env bash
# unload-wlan.sh - Unload BCM4389 Wi-Fi, Bluetooth, and PCIe modules in reverse dependency order
set -euo pipefail

TARGET_HOST="${TARGET_HOST:-172.16.42.1}"
TARGET_USER="${TARGET_USER:-user}"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-/home/gregor/phone-second-life-data/mb010/deploy-harden/ssh/known_hosts}"
if [ ! -f "${KNOWN_HOSTS_FILE}" ] && [ -f "/tmp/opencode/gs101/issue4/known_hosts" ]; then
    KNOWN_HOSTS_FILE="/tmp/opencode/gs101/issue4/known_hosts"
fi
SSH_OPTS="-i ~/.ssh/id_ed25519 -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3"

echo "=== Unloading BCM4389 WLAN & Bluetooth modules on ${TARGET_USER}@${TARGET_HOST} ==="

REVERSE_CHAIN="hci_uart btqca btbcm bluetooth bcmdhd cfg80211 rfkill pci-exynos"

if ping -c 1 -W 2 "${TARGET_HOST}" >/dev/null 2>&1; then
    for mod in ${REVERSE_CHAIN}; do
        echo "Unloading ${mod} ..."
        ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo rmmod ${mod} 2>/dev/null || true"
    done
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "lsmod | grep -E '(bcmdhd|cfg80211|rfkill|bluetooth|hci_uart|pci_exynos)' || echo 'All WLAN/BT modules successfully unloaded.'"
else
    echo "Host ${TARGET_HOST} not reachable over network. If running locally on target:"
    echo "  sudo rmmod hci_uart btqca btbcm bluetooth bcmdhd cfg80211 rfkill pci_exynos"
fi
