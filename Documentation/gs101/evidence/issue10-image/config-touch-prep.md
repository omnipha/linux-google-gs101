# Issue #10: Kernel Configuration Preparation — Touchscreen Driver Cleanup

**Date**: 2026-11-28  
**Scope**: Worktree `.config` modification and evidence documentation for Issue #10 (Pixel 6 Pro `raven` touchscreen bring-up).  
**Complementary Documents**:
- [kernel-config-audit.md](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue10-image/kernel-config-audit.md)
- [module-load-matrix.md](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue10-image/module-load-matrix.md)
- [gs101-raven.dts](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-raven.dts)

---

## 1. Objective & Policy (Issue #10)

Issue #10 specifies the following touch configuration requirement:
> *"Remove old s6sy761/fts drivers from config so they do not claim spi0.0"*  
> and deliver `sec_touch` built-in or in `vendor_boot`/`initramfs`.

### Device Tree Finding
In the Pixel 6 Pro device tree ([gs101-raven.dts](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-raven.dts#L121-L125)), the generic stub node is explicitly deleted and replaced with the Samsung `sec_ts` binding on `spi_touch` (`spi0.0`):
```dts
&spi_0 {
    /* ... */
    /delete-node/ touchscreen@0;

    touchscreen@0 {
        compatible = "sec,sec_ts";
        reg = <0>;
        spi-max-frequency = <10000000>;
        spi-cpol;
        spi-cpha;
        /* ... */
        sec,firmware_name = "s6sy79x.bin";
        /* ... */
    };
};
```
Having legacy `s6sy761` drivers enabled in `.config` (`CONFIG_TOUCHSCREEN_S6SY761=m`, `CONFIG_TOUCHSCREEN_S6SY761_SPI=m`) creates driver competition for the `spi0.0` peripheral. `STMFTS` was already disabled (`# CONFIG_TOUCHSCREEN_STMFTS is not set`), and `fts_spi` has no active Kconfig entry in this tree. Therefore, cleaning `S6SY761` completely eliminates rogue SPI touch drivers from the build.

---

## 2. Before / After Symbol Comparison (.config)

The configuration symbols were adjusted using `./scripts/config` without running `make olddefconfig` or invoking kernel build targets:

### Pre-Modification Baseline (.config)
```text
CONFIG_TOUCHSCREEN_S6SY761=m
CONFIG_TOUCHSCREEN_S6SY761_I2C=m
CONFIG_TOUCHSCREEN_S6SY761_SPI=m
# CONFIG_TOUCHSCREEN_STMFTS is not set
# CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI is not set
CONFIG_TOUCHSCREEN_SEC_TS=m
```

### Post-Modification Cleaned State (.config)
```text
# CONFIG_TOUCHSCREEN_S6SY761 is not set
# CONFIG_TOUCHSCREEN_S6SY761_I2C is not set
# CONFIG_TOUCHSCREEN_S6SY761_SPI is not set
# CONFIG_TOUCHSCREEN_STMFTS is not set
# CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI is not set
CONFIG_TOUCHSCREEN_SEC_TS=m
```

---

## 3. Deployment & Candidate Cycle Note

> [!IMPORTANT]
> **Candidate Image Invariant**:
> The currently prepared `cand22` `boot.img` was compiled prior to this `.config` modification and still carries the older modular configuration (`CONFIG_TOUCHSCREEN_S6SY761=m`).
> In adherence to the supervisor constraints, **no kernel or image build is performed in this steer**.
> This `.config` modification serves as verified offline preparation for the **subsequent flash cycle** following initial hardware bring-up and verification.

---

## 4. `sec_touch` Delivery & Vermagic Matching

As documented in [module-load-matrix.md §2](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue10-image/module-load-matrix.md#L47) and [cand13-flash-log.md](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue10-image/cand13-flash-log.md):
1. **Why `CONFIG_TOUCHSCREEN_SEC_TS=m` is Preserved**:
   Attempting to link `sec_touch` built-in into `vmlinux` (`=y`) causes the driver probe to run before PMIC regulators (`dvdd_tsp`, `avdd_ts`) or peripheral clocks have stabilized, causing early-boot kernel hangs prior to USB gadget / CDC-NCM initialization.
2. **Delivery Mechanism**:
   The modular driver `sec_touch.ko` is packaged directly into the initramfs ramdisk (`vendor_ramdisk00`) inside `vendor_boot.img`.
3. **Vermagic Alignment**:
   `sec_touch.ko` is built with vermagic:
   ```text
   7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
   ```
   This matches the running kernel `uname -r` (`7.3.0-rc6-gs101` without `+`) 1:1, ensuring seamless autoloading at boot without vermagic rejection.
