# Issue #8: Wi-Fi and Bluetooth Bring-up Investigation (BCM4389)

**Last Updated:** 2026-11-28 (Post-Steer28 Source Audit & Preparation)
**Target:** Google Pixel 6 Pro (`raven`) / Google Tensor GS101
**Scope:** Broadcom BCM4389 combo chipset (PCIe Wi-Fi 6E + UART Bluetooth 5.2) bring-up, devicetree integration, driver configuration, firmware management, and candidate packaging.

---

## 1. Hardware Identification
- **Chipset:** Broadcom BCM4389 (Murata Type 1WK combo module).
- **Features:** Wi-Fi 6E (802.11a/b/g/n/ac/ax, 2x2 MIMO, 2.4/5/6 GHz, tri-band) + Bluetooth 5.2.
- **Host Interfaces:**
  - **Wi-Fi:** PCIe Gen2/Gen3 single lane interface connected to SoC PCIe RC1 (`pcie@14520000`).
  - **Bluetooth:** 4-wire UART interface connected via USI16 (`serial@175b0000`) with out-of-band wake GPIOs.

---

## 2. Pinout and GPIO Analysis & Devicetree Implementation
From stock Pixel 6 Pro `raven` DTBO analysis and mainline implementation:

### 2.1 Bluetooth (USI16 / `serial_16`)
Implemented in [gs101-raven.dts](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-raven.dts) and [gs101.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101.dtsi) (Commit `e753933f5`):
- `usi_16: usi@175b0000` (mode: UART, sysreg: `sysreg_aud`).
- `serial_16: serial@175b0000` with child serdev node `bluetooth`:
  - `compatible = "brcm,bcm4389-bt", "brcm,bcm43438-bt";`
  - `shutdown-gpios`: `&gpp16 2 GPIO_ACTIVE_HIGH` (`bt-reg-on`, power enable).
  - `host-wakeup-gpios`: `&gpp16 0 GPIO_ACTIVE_HIGH` (`bt-host-wake`, interrupt to host).
  - `device-wakeup-gpios`: `&gpp14 3 GPIO_ACTIVE_HIGH` (`bt-dev-wake`, host wake signal to BCM4389).
  - `max-speed`: `<3000000>` (3.0 MBaud).
  - `vbat-supply`: `&vreg_conn_3p3`.
  - `vddio-supply`: `&vreg_conn_1p8`.

### 2.2 Wi-Fi (PCIe RC1)
Implemented in [gs101.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101.dtsi) (Commit `61b9b7368`):
- `pcie_1: pcie@14520000` (DesignWare PCIe Root Complex):
  - MMIO ranges: ELBI (`0x14520000`), DBI (`0x14500000`), PCS (`0x14510000`), PHY (`0x14530000`).
  - Clocks & resets: CMU HSI2 / Sysreg HSI2 (`0x14420000`).
  - Bus ranges: `<0x00 0xff>`, config space: `0x14600000`, 32-bit non-prefetchable memory: `0x14700000`.
  - `dma-coherent;` property set for hardware cache coherency.
  - Pin controls: `pcie0_clkreq` and `pcie0_perst`.
  - Power supplies: `vdd085_pcie0`, `vreg_conn_pa_1p8`, `vreg_conn_1p8`, `vreg_conn_3p3`.
  - Child node `wifi@0,0`:
    - `compatible = "android,bcmdhd_wlan", "pci14e4,4389";`
    - `reg = <0x000000 0 0 0 0>;`

---

## 3. Kernel Driver & Candidate Status

### 3.1 PCIe Controller Support
- **Status:** READY (Host-side prepared and packaged).
- Devicetree implementation active in `gs101.dtsi` (Commit `61b9b7368`).
- Driver: `drivers/pci/controller/dwc/pci-exynos.c` enabled as loadable module (`CONFIG_PCI_EXYNOS=m`, Commit `d0c70e3f4`).
- Candidate Images:
  - **`cand22 boot.img`**: Kernel 7.3.0-rc6-gs101 (Option A vermagic without `+`), SHA-256 `4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9`.
  - **`cand23 vendor_boot.img`**: Stock dual-FDT layout containing updated `gs101-raven.dtb` with `pcie@14520000`, SHA-256 `1d3f3a7e2fa2759d656651673b2ea0c84d0f92c53ff9d3a2e4766d19f0424c9d`.
  - Packaging and flash guards documented in [cand22-cand23-pci-exynos-prep.md](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue8-wireless/cand22-cand23-pci-exynos-prep.md).

### 3.2 Wi-Fi Driver Support (`bcmdhd`)
- **Status:** AUDITED & PREPARED (Out-of-tree source procured).
- Upstream `brcmfmac` does not support BCM4389.
- Broadcom/Google out-of-tree `bcmdhd` driver source procured from official AOSP mirror (`android15-6.1-qpr2`, commit `07aaee502e78656ae626ac214fb8f48d9a731cf8`) into external depot `/home/gregor/phone-second-life-data/mb010/bcmdhd-src/`.
- Full source audit and Linux 7.3 API delta analysis documented in [bcmdhd-source-audit.md](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue8-wireless/bcmdhd-source-audit.md).
- PCI device IDs confirmed: `0x14e4:0x4441` (programmed) and `0x14e4:0x4389` (pre-OTP).
- Compatibility deltas mapped: `strlcpy` -> `strscpy` shim, `class_create` 1-argument update, 36-bit DMA mask.

### 3.3 Bluetooth Driver & DT Support
- **Status:** READY (Host-side compiled and packaged).
- Kernel modules compiled with verified vermagic: `bluetooth.ko`, `btbcm.ko`, `hci_uart.ko`.
- Serdev devicetree node integrated into candidate 21/23 `vendor_boot.img`.

---

## 4. Firmware Availability & Depot Management

- **Status:** EXTRACTED & VERIFIED (Host external depot).
- All 16 required firmware blobs (18.1 MB) extracted directly from official Google Pixel 6 Pro factory image into `/home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/` (permissions `0700`, preserved outside repository per [AGENTS.md](file:///home/gregor/github_repos/linux-google-gs101/AGENTS.md)).
- Extracted Wi-Fi blobs:
  - `fw_bcmdhd.bin` (1,764,018 bytes)
  - `fw_bcmdhd.map` (1,855,772 bytes)
  - `bcmdhd.cal` + 5 regional/revision calibration variants (`cal_ROW`, `cal_JPN`, `cal_MMW`, `cal_PROTO1.0`, `cal_PROTO1.1`)
  - `bcmdhd_clm.blob` + 3 regional CLM variants (`clm_ROW`, `clm_JPN`, `clm_MMW`)
- Extracted Bluetooth blobs:
  - `BCM4389A1_004.002.007.0094.0135.hcd` (53,889 bytes) + 3 regional patch files.
- Full inventory and SHA-256 verification documented in [bcm4389-firmware-extraction.md](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue8-wireless/bcm4389-firmware-extraction.md).

---

## 5. Current Conclusion & Next Action

- **Overall Status:** HOST PREPARATION COMPLETE; TARGET TESTING PENDING DEVICE POWER-ON.
- **Hardware Blocker:** The target device (`raven`) remains completely powered off since Nov 26 04:04:28. The operator is handling physical hardware recovery. No fastboot or flash can be initiated until device power is restored.
- **Host Assets Ready:**
  1. PCIe RC1 devicetree and `CONFIG_PCI_EXYNOS=m` built into candidate images `cand22` & `cand23`.
  2. Bluetooth serdev devicetree and modules built.
  3. Firmware blobs extracted and cataloged outside the repository.
  4. Broadcom `bcmdhd` driver source procured from Android 15 QPR2 and audited for Linux 7.3 compatibility.
- **Next Operational Steps:**
  - Once operator powers on device: flash candidate images via verified single updater (`cand14-rollback.service`).
  - Verify PCIe controller enumeration via `lspci` / `/sys/bus/pci/`.
  - Apply `bcmdhd-7.3-compat.patch`, build `bcmdhd.ko`, load driver with extracted firmware, and bring up `wlan0`.
