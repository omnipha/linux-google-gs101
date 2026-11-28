# Issue #11 GPU Panfrost: Candidate 20 Preparation & Rollback Status

## 1. Status Overview

- **Overall Status**: `PACKAGE_BLOCKED`
- **Blocking Cause**: Device powered off / unresponsive since 2026-11-26 04:04:28 CET (early boot hang during cand19 built-in Panfrost probe). Physical operator intervention required (hardware force-off via Power + Volume Down into bootloader / fastboot mode).
- **Rollback Status**:
  - Initial rollback timeout cap reached at `2026-11-28 00:00:12 CET` after 24 hours of waiting with no fastboot device detected (`lsusb` clean, ping/fastboot/adb unreachable).
  - Re-armed via `systemd --user` transient unit `cand14-rollback.service` at `2026-11-28 00:11:03 CET` (Main PID 1432080).
  - Armed wait timeout cap: `2026-11-29 00:11:03 CET` (2880 × 30s).
  - Rollback script: `/tmp/opencode/gs101/cand14-rollback.sh`
  - Rollback log: `/tmp/opencode/gs101/evidence/rollback-cand14-20261128-001103.log`
  - Single flash writer rule: Strictly one flash writer active on the host, owned by `cand14-rollback.service`. No secondary flash writer.

---

## 2. Root Cause Analysis & Architecture Fixes

### A. Valhall MMU Page Table Incompatibility Fix
During Candidate 19 analysis, it was identified that ARM Valhall architecture (Mali-G78) strictly mandates 64-bit LPAE page tables (`ARM_64_LPAE_S1`). In `drivers/gpu/drm/panfrost/panfrost_mmu.c`:
```c
if (pfdev->comp->gpu_quirks & BIT(GPU_QUIRK_FORCE_AARCH64_PGTABLE)) {
    if (!panfrost_has_hw_feature(pfdev, HW_FEATURE_AARCH64_MMU)) {
        dev_err_once(pfdev->base.dev, "AARCH64_4K page table not supported\n");
        return ERR_PTR(-EINVAL);
    }
    fmt = ARM_64_LPAE_S1;
} else {
    fmt = ARM_MALI_LPAE;
}
```
In `drivers/gpu/drm/panfrost/panfrost_drv.c`, `gs101_data` lacked `.gpu_quirks = BIT(GPU_QUIRK_FORCE_AARCH64_PGTABLE)`. Consequently, Panfrost attempted to configure legacy Bifrost `ARM_MALI_LPAE` page tables, triggering an immediate hardware bus lockup upon register write.

**Fix Applied in `drivers/gpu/drm/panfrost/panfrost_drv.c`**:
```c
static const char * const gs101_supplies[] = { "mali", "buck8s", "ldo1s", "buck7m" };
static const struct panfrost_compatible gs101_data = {
	.num_supplies = ARRAY_SIZE(gs101_supplies) - 1,
	.supply_names = gs101_supplies,
	.num_pm_domains = 1, /* optional */
	.pm_domain_names = NULL,
	.gpu_quirks = BIT(GPU_QUIRK_FORCE_AARCH64_PGTABLE),
};
```

### B. Modular Panfrost Isolation (`CONFIG_DRM_PANFROST=m`)
To eliminate the risk of early boot hangs preventing userspace and USB initialization, Panfrost is decoupled from `vmlinux`:
- `CONFIG_DRM_PANFROST=m` in `.config`.
- Kernel `boot.img` boots cleanly using `simpledrm` for display console and Phosh.
- GPU testing is executed via live `insmod` of `panfrost.ko` from userspace over SSH. If an unhandled fault occurs, userspace, USB CDC-NCM, and SSH survive, capturing verbatim `dmesg` oops traces.

---

## 3. Artifact Hashes & Build Evidence

| Artifact | Location | SHA-256 Hash | Notes |
| :--- | :--- | :--- | :--- |
| **cand20 boot.img** | `/tmp/opencode/gs101/cand20/boot.img` | `4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9` | `CONFIG_DRM_PANFROST=m`, simpledrm console, vermagic `7.3.0-rc6-gs101` (Option A LOCALVERSION="") |
| **panfrost.ko** | `/tmp/opencode/gs101/cand20/modules/panfrost.ko` | `562f9bc1f377a3f028182402c61439e128ca9e67efe2ecab8f1196f5e308a5c4` | G78 entry (0x9002) + AArch64 MMU quirk |
| **gpu-sched.ko** | `/tmp/opencode/gs101/cand20/modules/gpu-sched.ko` | `eb00f25f5f61f9a3b70c6174781bf11878e35e67ec195d664bd6acb0af9967bf` | DRM scheduler dependency |
| **Rollback boot_a** | `/tmp/opencode/gs101/cand14/boot.img` | `84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36` | Target rollback image for cand14-rollback.service |

---

## 4. Flash Script Preparation (`flash-cand20.sh`)

- Script location: `/tmp/opencode/gs101/flash-cand20.sh`
- Execution constraints:
  - Flashes ONLY `boot_a` (no protected partitions, no vbmeta, no bootloader, no relock).
  - Single-shot execution guarded by explicit SHA-256 validation for both candidate and rollback images.
  - Generates structured JSON result with `flash_rc`, target partition, timestamp, and device serial.
  - **Armed status**: Script is created and verified, but NOT executed until operator fastboot recovery and supervisor instruction.

---

## 5. Post-Recovery Execution Plan

1. **Rollback Execution**:
   - Operator forces device off (Power + VolDown) into fastboot mode.
   - `cand14-rollback.service` catches fastboot device, flashes `cand14` `boot_a` (`84323d06`), sets slot `a`, and reboots.
2. **Baseline SSH Verification**:
   - Connect via SSH (`user@172.16.42.1`).
   - Verify `uname -a`, kernel command line (`console=tty0`), `/proc/consoles`, dmesg, and display state (Phoc/Phosh, `grim`).
   - Record rollback verification log reference in Issue #11.
3. **Candidate 20 Flash & Live Module Verification**:
   - Ensure rollback unit is inactive (`systemctl --user is-active cand14-rollback.service`).
   - Flash Candidate 20 `boot_a` via `/tmp/opencode/gs101/flash-cand20.sh`.
   - Verify boot into `simpledrm` over SSH.
   - Copy `gpu-sched.ko` and `panfrost.ko` to device.
   - Execute live `sudo insmod /tmp/gpu-sched.ko && sudo insmod /tmp/panfrost.ko`.
   - Capture `dmesg` output, check `/dev/dri/renderD128`, test `WLR_RENDERER=gles2` for Phoc, and record lag metrics.
4. **Issue #10 Application Persistence**:
   - Execute reboot persistence test and minimal application set installation.
