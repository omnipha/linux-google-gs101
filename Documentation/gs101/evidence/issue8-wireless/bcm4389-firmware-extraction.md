# Issue #8 Wireless: BCM4389 Firmware Extraction & Upstream Integration Audit

## 1. Overview & Provenance

This document records the offline firmware extraction and upstream driver integration analysis for the Broadcom BCM4389 combo Wi-Fi 6E / Bluetooth 5.2 chipset on Google Tensor GS101 (`raven` / Pixel 6 Pro).

### Source Archive & Hashes
- **Local Factory Image Archive**:
  `/home/gregor/phone-second-life-data/mb010/firmware/raven-cp3a.261005.002.a1-factory-2b76c8d1.zip`
- **Archive SHA-256 Checksum**: `2b76c8d122cbf38965f72671ebae5f3e9b1d9df2499684129eb4feae62121e7d`
- **Nested Factory Payload**: `raven-cp3a.261005.002.a1/image-raven-cp3a.261005.002.a1.zip`
- **Source Partition Image**: `vendor.img` (Linux rev 1.0 ext4 filesystem, 651,722,752 bytes = 621.5 MiB, UUID `88ffb9ba-d2c1-5de8-a287-42676b6a3464`)
- **Extraction Target Directory (OUTSIDE repository)**:
  `/home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/` (Permissions `0700` dir / `0600` files)

> [!IMPORTANT]
> **Proprietary Firmware Policy**:
> Zero proprietary binary firmware blobs are committed to the public Git repository. All binary artifacts remain strictly local on the host development machine in `/home/gregor/phone-second-life-data/` and deployed directly to `/lib/firmware/` on target rootfs.

---

## 2. Firmware Inventory & Cryptographic Checksums

All 16 BCM4389-related firmware files were extracted from `vendor.img` path `/firmware/`:

| File Name in `vendor.img` | Size (Bytes) | SHA-256 Checksum | Description / Function |
| :--- | :--- | :--- | :--- |
| `firmware/fw_bcmdhd.bin` | 1,764,018 | `3a6dbf5a726304f83e154ff1b265a06c77d669506eb5c784fd864f10bdda6533` | BCM4389 Wi-Fi 6E operational microcode binary |
| `firmware/fw_bcmdhd.map` | 1,855,772 | `a94c07725ac5b6132541052b7523f5f6afab020b8e9861f03e0a59b9b79ef727` | Firmware symbol address map for diagnostic traces |
| `firmware/bcmdhd.cal` | 24,530 | `a16987752c7de8b026d18c1348f350a48ec062e2570c44d6c778847fab8cc801` | Default / US Wi-Fi NVRAM calibration parameter table |
| `firmware/bcmdhd.cal_JPN` | 24,533 | `15a5ec62fc28713d99025e1399fd2e7ffe4a7a2a298a766e9d931ad9ff7f83f2` | Japan regulatory calibration parameter table |
| `firmware/bcmdhd.cal_MMW` | 24,534 | `660e584a76e1324dce50f551522153424e130c73ce410091f84def8570df7555` | mmWave SKU antenna calibration parameter table |
| `firmware/bcmdhd.cal_PROTO1.0` | 23,913 | `88896a2b1fc06037196558a0cadc0954df0fc09b79af83ced4e0d9897947c987` | Hardware Prototype 1.0 calibration table |
| `firmware/bcmdhd.cal_PROTO1.1` | 24,131 | `726056e25dfb730f948457aff85718d8aed687dcc5b824f689e7135de333b13f` | Hardware Prototype 1.1 calibration table |
| `firmware/bcmdhd.cal_ROW` | 24,497 | `e2950a43669d5e8654d49e891bf69753b986fe01dfde4bf818d50c8a224ad0ad` | Rest-of-World regulatory calibration parameter table |
| `firmware/bcmdhd_clm.blob` | 16,260 | `5ae4086e69f310f7a67df3a1e8e3537f229205c1ce2d7ad520e4217b04044d64` | Country Locale Matrix (CLM) regulatory limits blob |
| `firmware/bcmdhd_clm.blob_JPN` | 16,260 | `e6746939a038b63a7333363e15f960b2b6c2e098ff372b04acf177fcd3aa96ac` | Japan regulatory CLM limits blob |
| `firmware/bcmdhd_clm.blob_MMW` | 16,260 | `e6746939a038b63a7333363e15f960b2b6c2e098ff372b04acf177fcd3aa96ac` | mmWave regulatory CLM limits blob |
| `firmware/bcmdhd_clm.blob_ROW` | 16,260 | `5ae4086e69f310f7a67df3a1e8e3537f229205c1ce2d7ad520e4217b04044d64` | Rest-of-World regulatory CLM limits blob |
| `firmware/google_wifi_firmware_config_info.pb` | 513 | `fad8765802deef04b10fea417a4934c225b90d694f8aa232be87ac3a28cc10a7` | Google Wi-Fi firmware protobuf configuration metadata |
| `firmware/brcm/BCM.hcd` | 474,858 | `33124cc86e78563c3c730c76f1630ec2790be63cadc441bcda352c44b07c223c` | BCM4389 Bluetooth RAM patch file (Default) |
| `firmware/brcm/BTFW_B.hcd` | 474,047 | `429e254d0c139f7e3ed8b04fc369d8b3bfcd1aaf2c31c389359c6ddbe21a5d62` | BCM4389 Bluetooth RAM patch file (Hardware Rev B) |
| `firmware/brcm/BTFW_D.hcd` | 474,861 | `7d029d2fd3f7a8dbc70f5623eb7fa896f3beee48c9247c3f98231a36d8a6210b` | BCM4389 Bluetooth RAM patch file (Hardware Rev D) |

---

## 3. Upstream Driver Bind Capability Evaluation

### A. Wi-Fi: Upstream `brcmfmac` Support for BCM4389
An audit of `drivers/net/wireless/broadcom/brcm80211/brcmfmac/` in the active kernel source tree (`7.3.0-rc6-gs101+`) reveals:
1. **Missing PCI Device Table ID**:
   In `drivers/net/wireless/broadcom/brcm80211/brcmfmac/pcie.c` (lines 2735–2766), the `brcmf_pcie_devid_table` supports legacy Broadcom PCIe chipsets up to BCM4387:
   ```c
   BRCMF_PCIE_DEVICE(BRCM_PCIE_4377_DEVICE_ID, WCC_SEED),
   BRCMF_PCIE_DEVICE(BRCM_PCIE_4378_DEVICE_ID, WCC_SEED),
   BRCMF_PCIE_DEVICE(BRCM_PCIE_4387_DEVICE_ID, WCC_SEED),
   BRCMF_PCIE_DEVICE(BRCM_PCIE_43752_DEVICE_ID, WCC_SEED),
   ```
   **BCM4389 (Chip-ID `0x4389`) is NOT present** in `brcmf_pcie_devid_table`, `brcm_hw_ids.h`, or `chip.c`.
2. **Firmware Architecture Mismatch**:
   - Upstream `brcmfmac` requires FullMAC firmware files structured as `brcmfmac<chip>-pcie.bin`, `brcmfmac<chip>-pcie.clm_blob`, and `brcmfmac<chip>-pcie.txt`.
   - The extracted vendor firmware is designed for Broadcom's proprietary out-of-tree Android `bcmdhd` driver (`android,bcmdhd_wlan`), using `fw_bcmdhd.bin`, `bcmdhd_clm.blob`, and `bcmdhd.cal`.
3. **Verdict**: Upstream `brcmfmac` cannot bind to the BCM4389 PCIe endpoint without downstream driver backports or an out-of-tree `bcmdhd` driver module.

### B. Bluetooth: Upstream `btbcm` Support for BCM4389
An audit of `drivers/bluetooth/btbcm.c` and `hci_bcm.c` demonstrates:
1. **Native HCD Firmware Compatibility**:
   In `drivers/bluetooth/btbcm.c` (lines 650–670), the firmware loading routine automatically probes the firmware search paths:
   ```c
   snprintf(fn, sizeof(fn), "brcm/%s%s.hcd", hw_name, postfix);
   ...
   snprintf(fn, sizeof(fn), "brcm/BCM%s.hcd", postfix);
   ```
   The extracted files (`brcm/BCM.hcd`, `brcm/BTFW_B.hcd`, `brcm/BTFW_D.hcd`) directly match the naming conventions expected by `btbcm`.
2. **UART Line Discipline & Protocol**:
   The hardware connects to the SoC via standard Broadcom 4-wire UART protocol (`HCI_UART_BCM`), which is fully supported by `CONFIG_BT_HCIUART_BCM=y` and BlueZ `btattach -B /dev/ttySAC2 -P bcm`.
3. **Verdict**: Upstream Bluetooth driver support is **feasible and verified** once the UART interface and power GPIOs are exposed.

---

## 4. Required Device Tree (DTS) Implementation Work

### A. Wi-Fi (PCIe Root Complex 1)
To enable the Wi-Fi PCIe endpoint to enumerate on the bus:
1. **PCIe Controller DT Node (`pcie@14520000`)**:
   - In `gs101-overlay-anchors.dtsi`:
     ```dts
     pcie_1: anchor-pcie_1 { };
     ```
     is currently an unpopulated stub.
   - A complete Exynos DWC-based PCIe Root Complex node must be implemented in `gs101.dtsi` specifying:
     - Register ranges: DBI, ELBI (`0x14520000`), ATU, and PHY registers.
     - Clocks: CMU PCIe reference clocks and bus clocks.
     - Interrupts: PCIe MSI and link status interrupts.
     - Reset & Pinctrl: `pcie1_clkreq` and `pcie1_perst` pinctrl groups (already defined in `gs101-pinctrl.dtsi`).
2. **Power Regulators & Control GPIOs**:
   - Power supplies: `vdd085_pcie1` (PMIC Buck) and `vdd18_pcie1` (PMIC LDO) from `gs101-pixel-common.dtsi`.
   - Out-of-band signals: `wl_reg_on` (power enable GPIO), `wl_host_wake` (PCIe wake interrupt).

### B. Bluetooth (APM UART16 / USI1 Serdev)
To enable the kernel to automatically instantiate the Bluetooth device at boot:
1. **APM USI1 / UART16 DT Node (`serial@175b0000`)**:
   - Mainline `gs101-overlay-anchors.dtsi` leaves `serial_16: anchor-serial_16 { };` as an empty stub.
   - Must be defined as a full `samsung,exynos850-uart` device with:
     - Register range: `0x175b0000` (size `0x100`).
     - Clocks: `cmu_apm` indices 22 (`PCLK`), 21 (`IPCLK`), 47 (`GATE`).
     - Interrupts: GIC-v3 SPI 69.
     - Pinctrl: `uart16_bus` (`gpa3-0`..`gpa3-3` pin function `2`).
2. **Child Serdev Node in `gs101-raven.dts`**:
   ```dts
   &serial_16 {
       status = "okay";
       pinctrl-0 = <&uart16_bus>;
       pinctrl-names = "default";

       bluetooth {
           compatible = "brcm,bcm4349-bt", "brcm,bcm43438-bt";
           shutdown-gpios = <&gpp16 2 GPIO_ACTIVE_HIGH>;    /* bt-reg-on */
           device-wakeup-gpios = <&gpp14 3 GPIO_ACTIVE_HIGH>; /* bt-dev-wake */
           host-wakeup-gpios = <&gpa6 6 GPIO_ACTIVE_HIGH>;   /* bt-host-wake */
           interrupt-parent = <&gpa6>;
           interrupts = <6 IRQ_TYPE_EDGE_RISING>;
           interrupt-names = "host-wakeup";
           max-speed = <3000000>;
       };
   };
   ```
