# Issue #8: Wi-Fi and Bluetooth Bring-up Investigation (BCM4389)

## 1. Hardware Identification
- **Chipset:** Broadcom BCM4389 (Murata Type 1WK combo module).
- **Features:** Wi-Fi 6E (802.11a/b/g/n/ac/ax, 2x2 MIMO, 2.4/5/6 GHz) + Bluetooth 5.2.
- **Host Interfaces:**
  - **Wi-Fi:** PCIe Gen2/Gen3 single lane interface connected to SoC PCIe RC1 (`pcie@14520000`).
  - **Bluetooth:** 4-wire UART interface (`serial@109...` or USI) with out-of-band wake GPIOs.

## 2. Pinout and GPIO Analysis (Stock DTBO Extraction)
From stock Pixel 6 Pro raven DTBO fragments:
- **Bluetooth:**
  - `shutdown-gpios`: `gpp16-2` (`bt-reg-on`, active high power enable).
  - `host-wakeup-gpios`: `gpp16-0` (`bt-host-wake`, interrupt to host).
  - `device-wakeup-gpios`: `gpp14-3` (`bt-dev-wake`, host wake signal to BCM4389).
- **Wi-Fi:**
  - `wl_reg_on`: WLAN power enable.
  - `wl_host_wake`: PCIe wake interrupt.
  - `wl_dev_wake`: Host wake signal.
  - PCIe link: GS101 PCIe RC1 (`pcie@14520000`, ELBI/DBI/PCS/PHY).

## 3. Mainline Kernel (7.3.0-rc6-gs101) Driver & DT Status
1. **PCIe Controller Support:**
   - Upstream `gs101.dtsi` does not implement the Exynos GS101 PCIe root complex (`pcie@11920000` / `pcie@14520000`).
   - `arch/arm64/boot/dts/exynos/google/gs101-overlay-anchors.dtsi` contains only empty stub anchors:
     ```dts
     pcie_0: anchor-pcie_0 { };
     pcie_1: anchor-pcie_1 { };
     ```
   - In sysfs, `/sys/bus/pci/devices/` is empty; no PCIe bus is enumerated.
2. **Wi-Fi Driver Support:**
   - In-tree `brcmfmac` (`drivers/net/wireless/broadcom/brcm80211/brcmfmac`) does not support BCM4389.
   - Stock Android uses Broadcom's out-of-tree `bcmdhd` driver (`android,bcmdhd_wlan`), which is not present in upstream Linux.
3. **Bluetooth Driver & DT Support:**
   - Kernel config has `CONFIG_BT_HCIUART=m`, `CONFIG_BT_HCIUART_BCM=y`, `CONFIG_BT_BCM=m`.
   - However, `arch/arm64/boot/dts/exynos/google/gs101-raven.dts` does not contain a Bluetooth serdev node defining the BCM UART device and its GPIOs.

## 4. Firmware Availability
- **Required Blobs:**
  - Wi-Fi: `brcmfmac4389-pcie.bin`, `brcmfmac4389-pcie.clm_blob`, `brcmfmac4389-pcie.txt` (NVRAM).
  - Bluetooth: `BCM4389A1.hcd` (RAM patchfile loaded over HCI UART).
- **Firmware Status:**
  - Not present in device rootfs (`/lib/firmware/` only has `s6sy79x.bin`).
  - Not distributed in upstream `linux-firmware.git` due to proprietary licensing terms.
  - Upstream source: Google factory image for raven (e.g. `raven-ota-*.zip` or `vendor.img` under `/vendor/firmware/`).
  - Per repository rules (`AGENTS.md`), no proprietary blobs may be committed to this repository.

## 5. Conclusion & Block Status
- **Status:** BLOCKED.
- **Reason:** BCM4389 firmware blobs are not present in rootfs/repository; GS101 PCIe RC controller is unmapped in mainline DTS; BCM4389 is unsupported in upstream `brcmfmac`.
- Proceeding to Issue #10 packaging per task instructions.
