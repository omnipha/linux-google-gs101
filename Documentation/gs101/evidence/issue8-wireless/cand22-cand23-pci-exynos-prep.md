# Issue #8 Offline Preparation: `CONFIG_PCI_EXYNOS=m` Activation & Candidate 22/23 Artifact Generation

**Date**: 2026-11-28
**Scope**: Issue #8 Wireless offline preparation (steer27)
**Kernel Baseline**: Linux `7.3.0-rc6-gs101` (Option A LOCALVERSION, without `+`)
**Target Artifacts**:
- `cand22 boot.img` (`/tmp/opencode/gs101/cand22/boot.img`)
- `cand23 vendor_boot.img` (`/tmp/opencode/gs101/cand23/vendor_boot.img`)
- `pci-exynos.ko` (`/tmp/opencode/gs101/cand22/modules/pci-exynos.ko`)
- Flash scripts: `flash-cand22.sh` and `flash-cand23.sh`
**Status**: Static compilation and artifact packaging complete; NO flash performed; device offline awaiting operator physical action.

---

## 1. Executive Summary

Following the devicetree implementation of PCIe Root Complex 1 (`pcie_1` / `pcie@14520000`, Commit `61b9b7368`), the kernel configuration was audited. While the device tree declared compatibility with `"samsung,exynos5433-pcie"`, `.config` previously had `# CONFIG_PCI_EXYNOS is not set`.

Under steer27, `CONFIG_PCI_EXYNOS=m` has been activated, building the Exynos PCIe host controller driver as a standalone module (`pci-exynos.ko`). Candidate artifacts `cand22` (`boot.img`) and `cand23` (`vendor_boot.img`) were generated, byte-verified, and guarded with dedicated flash scripts.

---

## 2. Configuration Rationale: `CONFIG_PCI_EXYNOS=m` vs `=y`

The decision to configure `CONFIG_PCI_EXYNOS=m` rather than `=y` is founded on strict boot safety and regression isolation principles:

1. **Boot Safety & Failure Mitigation (cand13 / cand19 Lessons Learned)**:
   - If built-in (`=y`), `exynos_pcie_probe()` executes synchronously during early platform device scanning before init or userspace starts.
   - Upstream `drivers/pci/controller/dwc/pci-exynos.c` expects Exynos5433-style ELBI registers and a mandatory generic PHY (`devm_of_phy_get()`).
   - On GS101, accessing unclocked/unpowered ELBI registers or missing a PHY node could trigger an asynchronous external abort (SError) or panic during early boot. A failure at this stage causes a bootloop and triggers the rollback watchdog.
   - With `CONFIG_PCI_EXYNOS=m`, early boot is completely untouched. The kernel boots cleanly into userspace (SSH/init). Testing can be performed under controlled userspace supervision via `modprobe pci-exynos`.

2. **Vermagic & Module Tree Consistency**:
   - Built with `LOCALVERSION=""`, `pci-exynos.ko` carries the exact vermagic `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` without `+`.
   - This matches `sec_touch.ko` in `vendor_ramdisk00`, rootfs `/usr/lib/modules/7.3.0-rc6-gs101/`, and previous candidate modules (`panfrost.ko`, `gpu-sched.ko`, `hci_uart.ko`, `bluetooth.ko`).

3. **Core DWC Framework Availability**:
   - `CONFIG_PCIE_DW=y` and `CONFIG_PCIE_DW_HOST=y` are built into the kernel, providing the Synopsys DesignWare host core infrastructure while leaving the Exynos glue modularized.

---

## 3. Configuration & Modinfo Verification

### 3.1 `.config` Diff
```diff
--- .config.prev
+++ .config
@@ -1795,7 +1795,7 @@
 CONFIG_PCIE_KIRIN=y
 # CONFIG_PCIE_DW_PLAT_HOST is not set
 # CONFIG_PCIE_DW_PLAT_EP is not set
-# CONFIG_PCI_EXYNOS is not set
+CONFIG_PCI_EXYNOS=m
 # end of DesignWare-based PCIe controllers
```

### 3.2 `modinfo` Audit (`pci-exynos.ko`)
Running `/usr/sbin/modinfo /tmp/opencode/gs101/cand22/modules/pci-exynos.ko` confirms:
```text
filename:       /tmp/opencode/gs101/cand22/modules/pci-exynos.ko
description:    Samsung Exynos PCIe host controller driver
license:        GPL v2
name:           pci_exynos
intree:         Y
depends:
alias:          of:N*T*Csamsung,exynos5433-pcieC*
alias:          of:N*T*Csamsung,exynos5433-pcie
vermagic:       7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
```
- **Driver Match**: Matches device tree compatible string `"samsung,exynos5433-pcie"` on node `/soc@0/pcie@14520000`.
- **Vermagic**: Exactly `7.3.0-rc6-gs101` (Option A verified).

### 3.3 Static Driver Binding & Open Items Analysis
1. **Regulators**:
   - `pci-exynos.c` probes `ep->supplies[0] = "vdd18"` and `ep->supplies[1] = "vdd10"`.
   - Node `&pcie_1` in `gs101-raven.dts` provides `vdd18-supply = <&ldo19m>` and `vdd10-supply = <&ldo17m>`. Static requirement satisfied.
2. **Clocks**:
   - `pci-exynos.c` uses `devm_clk_bulk_get_all_enabled()`, which successfully consumes all clocks mapped from `cmu_hsi2`.
3. **PHY Integration**:
   - `pci-exynos.c` calls `ep->phy = devm_of_phy_get(dev, np, NULL)`.
   - Mainline GS101 currently does not define a separate generic PHY node for HSI2 PCIe (as stock Samsung uses integrated PMU/CMU sequencing).
   - If loaded on GS101 without a separate PHY node, `pci-exynos.ko` will fail probe gracefully with `-ENODEV` (or `PTR_ERR(ep->phy)`), which does NOT crash or panic the operating system.
4. **No Hardware Claims**:
   - Devicetree and kernel modules are aligned. No claims regarding physical link training or endpoint enumeration are made without physical device access.

---

## 4. Artifact Build & Reverse Verification Evidence

### 4.1 Candidate 22 (`boot.img`)
- **Build Recipe**:
  ```bash
  mkbootimg --header_version 4 --kernel arch/arm64/boot/Image.lz4 --output /tmp/opencode/gs101/cand22/boot.img
  ```
- **Inspection (`unpack_bootimg`)**:
  - Boot magic: `ANDROID!`
  - Header version: `4`
  - Kernel size: `14,511,885` bytes
  - Ramdisk size: `0`
  - Command line: empty
- **SHA-256 Hash**: `4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9`
  *(Note: Byte-identical to cand20 because `CONFIG_PCI_EXYNOS=m` is modularized; `pci-exynos.ko` is provided in `/tmp/opencode/gs101/cand22/modules/`)*.

### 4.2 Candidate 23 (`vendor_boot.img`)
- **Build Recipe**:
  1. Build dual-FDT DTB region with `/tmp/opencode/gs101/build_dtb_region.py`:
     ```bash
     python3 /tmp/opencode/gs101/build_dtb_region.py arch/arm64/boot/dts/exynos/google/gs101-raven.dtb /tmp/opencode/gs101/cand23/raven-region.dtb
     ```
  2. Assemble `vendor_boot.img` with stock geometry:
     ```bash
     mkbootimg \
       --header_version 4 \
       --pagesize 0x00000800 \
       --base 0x00000000 \
       --kernel_offset 0x10008000 \
       --ramdisk_offset 0x11000000 \
       --tags_offset 0x10000100 \
       --dtb_offset 0x0000000011f00000 \
       --vendor_cmdline 'loglevel=8 clk_ignore_unused regulator_ignore_unused loop.max_part=7 printk.devkmsg=on console=tty0 fbcon=font:TER16x32 consoleblank=0 pmos_boot_uuid=dcca49fa-fc71-498e-9f4f-09f2b80edaf1 pmos_root_uuid=0bcaadf4-9a11-4422-9a03-e297f1e97aaf pmos_rootfsopts=defaults' \
       --board '' \
       --dtb /tmp/opencode/gs101/cand23/raven-region.dtb \
       --vendor_bootconfig /tmp/opencode/gs101/cand23/bootconfig \
       --ramdisk_type 1 \
       --ramdisk_name '' \
       --vendor_ramdisk_fragment /tmp/opencode/gs101/cand23/vendor_ramdisk00 \
       --vendor_boot /tmp/opencode/gs101/cand23/vendor_boot.img
     ```
- **Reverse Verification (`unpack_bootimg`)**:
  - Vendor boot magic: `VNDRBOOT`
  - Header version: `4`
  - DTB size: `536,176` bytes (stock size)
  - Both FDT #0 (268,095 B) and FDT #1 (268,081 B) decompiled with `dtc` and verified:
    - Node `/soc@0/pcie@14520000`: `status = "okay"`
    - Child `wifi@0,0`: `compatible = "android,bcmdhd_wlan", "pci14e4,4389"`
    - Node `/soc@0/usi@175b00c0`: `status = "okay"`
    - Node `/soc@0/usi@175b00c0/serial@175b0000`: `status = "okay"`
    - Child `bluetooth`: `compatible = "brcm,bcm4349-bt", "brcm,bcm43438-bt"`
  - `vendor_ramdisk00`: Byte-identical to `cand18` and `cand21` (`23,905,675` bytes, sha256: `e8198d3bc7162d2dbe84a145e4f19c011c0bf007ffaf25df3e6ec131628629de`).
  - `bootconfig`: Byte-identical to `cand18` and `cand21` (0 bytes).
- **SHA-256 Hash**: `1d3f3a7e2fa2759d656651673b2ea0c84d0f92c53ff9d3a2e4766d19f0424c9d`

---

## 5. Artifact Hash Matrix & Script Guard Synchronization

| Artifact | File Path | SHA-256 Checksum | Description / Role |
| :--- | :--- | :--- | :--- |
| **cand22 boot.img** | `/tmp/opencode/gs101/cand22/boot.img` | `4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9` | Target `boot_a` (Panfrost + PCIe modular) |
| **pci-exynos.ko** | `/tmp/opencode/gs101/cand22/modules/pci-exynos.ko` | `67e37cd087a2b16b63e8ac578ddcc02a3d7b6e2f3c76ec95c86037ab13d0342d` | Exynos PCIe host driver module |
| **cand23 vendor_boot.img** | `/tmp/opencode/gs101/cand23/vendor_boot.img` | `1d3f3a7e2fa2759d656651673b2ea0c84d0f92c53ff9d3a2e4766d19f0424c9d` | Target `vendor_boot_a` (PCIe + USI16 DTB) |
| **cand14 boot.img** | `/tmp/opencode/gs101/cand14/boot.img` | `84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36` | Rollback reference `boot_a` |
| **cand18 vendor_boot.img** | `/tmp/opencode/gs101/cand18/vendor_boot.img` | `8a6840fbbc2035862a46123f5b25539d1085903a16d38a8904bb2966142ac818` | Rollback reference `vendor_boot_a` |

### Flash Scripts Guarding:
- [flash-cand22.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue8-wireless/flash-cand22.sh) (`/tmp/opencode/gs101/flash-cand22.sh`):
  - `EXPECT_CAND22_BOOT="4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9"`
  - `EXPECT_ROLLBACK_BOOT="84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36"`
- [flash-cand23.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue8-wireless/flash-cand23.sh) (`/tmp/opencode/gs101/flash-cand23.sh`):
  - `EXPECT_CAND22_BOOT="4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9"`
  - `EXPECT_CAND23_VENDOR="1d3f3a7e2fa2759d656651673b2ea0c84d0f92c53ff9d3a2e4766d19f0424c9d"`
  - `EXPECT_ROLLBACK_BOOT="84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36"`
  - `EXPECT_ROLLBACK_VENDOR="8a6840fbbc2035862a46123f5b25539d1085903a16d38a8904bb2966142ac818"`

Both scripts contain:
1. `cand14-rollback.service` active guard (`exit 3` if active).
2. Exact SHA-256 verification of targets and rollback baselines (`exit 1` on mismatch).
3. SSH reboot detection with single-shot 30s fastboot wait.
4. Output of structured JSON result logs to `/tmp/opencode/gs101/evidence/`.
5. Neither script has been executed.
