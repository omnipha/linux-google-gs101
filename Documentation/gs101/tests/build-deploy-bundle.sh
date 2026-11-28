#!/usr/bin/env bash
# build-deploy-bundle.sh - Canonical and Reproducible Deployment Bundle Builder for Google Tensor GS101
# Assembles out-of-tree WLAN/BT drivers, Panfrost GPU modules, BCM4389 firmware, and deployment scripts
# into the persistent preparation bundle archive with depmod indexing and SHA256 integrity verification.
# NOTE: Host-side offline packaging only. Zero kernel compilation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_VER="${KERNEL_VER:-7.3.0-rc6-gs101}"

# Permanent source and destination directories (overridable via ENV)
BUNDLE_SRC_MODULES="${BUNDLE_SRC_MODULES:-/home/gregor/phone-second-life-data/mb010/deploy-harden/modules}"
BUNDLE_SRC_GPU_MODULES="${BUNDLE_SRC_GPU_MODULES:-/home/gregor/phone-second-life-data/mb010/deploy-harden/gpu-modules}"
BUNDLE_SRC_FIRMWARE="${BUNDLE_SRC_FIRMWARE:-/home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware}"
BUNDLE_OUT="${BUNDLE_OUT:-/home/gregor/phone-second-life-data/mb010/bundles/gs101-prep-bundle-20261128.tar.gz}"

echo "=== Google Tensor GS101 Canonical Deployment Bundle Builder ==="
echo "Kernel Release:     ${KERNEL_VER}"
echo "WLAN/BT Modules:    ${BUNDLE_SRC_MODULES}"
echo "GPU Modules:        ${BUNDLE_SRC_GPU_MODULES}"
echo "Firmware Depot:     ${BUNDLE_SRC_FIRMWARE}"
echo "Output Archive:     ${BUNDLE_OUT}"

# Validate source inputs
if [ ! -d "${BUNDLE_SRC_MODULES}" ]; then
    echo "ERROR: WLAN/BT module directory not found: ${BUNDLE_SRC_MODULES}" >&2
    exit 1
fi
if [ ! -d "${BUNDLE_SRC_GPU_MODULES}" ]; then
    echo "ERROR: GPU module directory not found: ${BUNDLE_SRC_GPU_MODULES}" >&2
    exit 1
fi
if [ ! -d "${BUNDLE_SRC_FIRMWARE}" ]; then
    echo "ERROR: Firmware directory not found: ${BUNDLE_SRC_FIRMWARE}" >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d /tmp/gs101-bundle-staging.XXXXXX)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

BUNDLE_DIR="${STAGING_DIR}/wlan-bundle"
MOD_DEST="${BUNDLE_DIR}/lib/modules/${KERNEL_VER}/extra"
FW_DEST="${BUNDLE_DIR}/lib/firmware"

mkdir -p "${MOD_DEST}"
mkdir -p "${FW_DEST}/brcm"

echo "[1/6] Staging WLAN, Bluetooth, and PCIe kernel modules ..."
cp -p "${BUNDLE_SRC_MODULES}"/*.ko "${MOD_DEST}/"

echo "[2/6] Staging GPU modules (panfrost.ko, gpu-sched.ko) ..."
cp -p "${BUNDLE_SRC_GPU_MODULES}/panfrost.ko" "${MOD_DEST}/"
cp -p "${BUNDLE_SRC_GPU_MODULES}/gpu-sched.ko" "${MOD_DEST}/"

echo "[3/6] Staging BCM4389 firmware and NVRAM calibration blobs ..."
cp -p "${BUNDLE_SRC_FIRMWARE}"/bcmdhd* "${FW_DEST}/" 2>/dev/null || true
cp -p "${BUNDLE_SRC_FIRMWARE}"/fw_bcmdhd* "${FW_DEST}/" 2>/dev/null || true
cp -p "${BUNDLE_SRC_FIRMWARE}"/google_wifi* "${FW_DEST}/" 2>/dev/null || true
cp -p "${BUNDLE_SRC_FIRMWARE}"/brcm/* "${FW_DEST}/brcm/" 2>/dev/null || true

echo "[4/6] Generating module dependency tree via depmod -b ..."
/sbin/depmod -b "${BUNDLE_DIR}" "${KERNEL_VER}"

echo "[5/6] Staging versioned deployment scripts and metadata ..."
cp -p "${SCRIPT_DIR}/install-wlan.sh" "${BUNDLE_DIR}/"
cp -p "${SCRIPT_DIR}/unload-wlan.sh" "${BUNDLE_DIR}/"
cp -p "${SCRIPT_DIR}/install-gpu.sh" "${BUNDLE_DIR}/"
cp -p "${SCRIPT_DIR}/unload-gpu.sh" "${BUNDLE_DIR}/"
cp -p "${SCRIPT_DIR}/install-apps.sh" "${BUNDLE_DIR}/"
cp -p "${SCRIPT_DIR}/verify-recovery.sh" "${STAGING_DIR}/"

cat << 'README_EOF' > "${BUNDLE_DIR}/README.md"
# GS101 (raven) Canonical Deployment Bundle

This bundle packages out-of-tree Broadcom `bcmdhd` driver, PCIe controller (`pci-exynos.ko`), Bluetooth serdev modules (`bluetooth.ko`, `hci_uart.ko`, `btbcm.ko`, `btqca.ko`), wireless core (`cfg80211.ko`, `rfkill.ko`), Arm Mali-G78 Panfrost GPU drivers (`panfrost.ko`, `gpu-sched.ko`), BCM4389 firmware blobs, calibration files, and module dependency metadata for Google Tensor GS101 running Linux 7.3 (`7.3.0-rc6-gs101`).

## 1. Bundle Component Inventory
- 10 Kernel Modules in `lib/modules/7.3.0-rc6-gs101/extra/`:
  - `pci-exynos.ko`: GS101 PCIe root complex controller (`CONFIG_PCI_EXYNOS=m`)
  - `bcmdhd.ko`: Broadcom FullMAC PCIe driver (Linux 7.3 port)
  - `cfg80211.ko`, `rfkill.ko`: Wireless configuration core and radio killswitch
  - `bluetooth.ko`, `hci_uart.ko`, `btbcm.ko`, `btqca.ko`: Bluetooth serdev subsystem
  - `panfrost.ko`, `gpu-sched.ko`: Mali-G78 GPU acceleration stack (`CONFIG_DRM_PANFROST=m`)
- 16 Firmware & Calibration Blobs in `lib/firmware/`
- Operational Scripts: `install-wlan.sh`, `unload-wlan.sh`, `install-gpu.sh`, `unload-gpu.sh`, `install-apps.sh`
- Acceptance Verification: `verify-recovery.sh` (top-level)

## 2. Integrity Verification
Run `sha256sum -c SHA256SUMS` inside the bundle root directory.
README_EOF

# Generate internal SHA256SUMS
(
    cd "${BUNDLE_DIR}"
    find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
)

echo "[6/6] Creating compressed tarball and checksum ..."
mkdir -p "$(dirname "${BUNDLE_OUT}")"
tar czf "${BUNDLE_OUT}" -C "${STAGING_DIR}" wlan-bundle verify-recovery.sh
sha256sum "${BUNDLE_OUT}" > "${BUNDLE_OUT}.sha256"

# Verify tarball integrity
(
    cd "$(dirname "${BUNDLE_OUT}")"
    sha256sum -c "$(basename "${BUNDLE_OUT}.sha256")"
)
tar -tzf "${BUNDLE_OUT}" | grep -E "(panfrost\.ko|gpu-sched\.ko|bcmdhd\.ko)" >/dev/null

echo "=== Bundle Build Successfully Completed ==="
echo "Artifact:   ${BUNDLE_OUT}"
echo "Checksum:   $(cat "${BUNDLE_OUT}.sha256")"
echo "Total Files in Archive: $(tar -tzf "${BUNDLE_OUT}" | wc -l)"
