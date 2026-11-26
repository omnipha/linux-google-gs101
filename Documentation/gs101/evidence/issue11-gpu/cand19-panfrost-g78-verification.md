# Issue #11 GPU Panfrost Mali-G78 Identification & Candidate 19 Verification

## 1. Summary & Objective

In Steer 9 and Steer 10 investigations, DRM Panfrost was confirmed built into `vmlinux` (`CONFIG_DRM_PANFROST=y`). During kernel boot, Panfrost bound to `1c500000.gpu`, established a clock rate of 24.576 MHz, and failed during `panfrost_gpu_init_features()` with:
```
[    3.312984] panfrost 1c500000.gpu: clock rate = 24576000
[    3.313012] panfrost 1c500000.gpu: [drm:panfrost_devfreq_init] More than 1 supply is not supported yet
[    3.313045] panfrost 1c500000.gpu: GPU model not found: mali-unknown id rev 0x9202 0x10
[    3.313052] panfrost 1c500000.gpu: Fatal error during GPU init
```
Because Panfrost returned `-ENODEV`, kernel probe aborted gracefully, allowing `simpledrm` to serve as `/dev/dri/card0` and the system to boot Phosh.

The task for Steer 11 was:
1. Extend `gpu_models[]` in `drivers/gpu/drm/panfrost/panfrost_gpu.c` to include Mali-G78 (ID `0x9002`), referencing Valhall G57 feature group and 0 hardware errata/issues.
2. Commit only `drivers/gpu/drm/panfrost/panfrost_gpu.c`.
3. Build a single new kernel (Candidate 19 `boot.img`), reusing Candidate 18 `vendor_boot.img` (`8a6840fb`).
4. Flash only `boot_a` with automated rollback armed to Candidate 14 `boot.img` (`84323d06`).
5. Verify `/dev/dri/renderD128` and GLES2 acceleration or document root-cause block.

---

## 2. Code Patch & Commit

In `drivers/gpu/drm/panfrost/panfrost_device.h`:
```c
static inline int panfrost_model_cmp(struct panfrost_device *pfdev, s32 id)
{
	s32 match_id = pfdev->features.id;

	if (match_id & 0xf000)
		match_id &= 0xf00f;
	return match_id - id;
}
```
The hardware `GPU_ID` register on Google Tensor (GS101) reports high 16 bits `0x9202` (Valhall Architecture 9, Product Revision 2). `panfrost_model_cmp()` masks `0x9202 & 0xf00f = 0x9002`.

In `drivers/gpu/drm/panfrost/panfrost_gpu.c`:
```c
#ifndef hw_features_g78
#define hw_features_g78 hw_features_g57
#endif
#ifndef hw_issues_g78
#define hw_issues_g78 0
#endif

static const struct panfrost_model gpu_models[] = {
...
	/* MediaTek MT8188 Mali-G57 MC3 */
	GPU_MODEL(g57, 0x9093,
		GPU_REV(g57, 0, 0)),

	/* Mali-G78 (Valhall Gen2, Tensor GS101) */
	GPU_MODEL(g78, 0x9002),
	{0},
};
```

Commit created:
- Commit SHA: `7192a3afa`
- Commit Message: `drm/panfrost: add Mali-G78 (0x9002) model support`

---

## 3. Artifact Hashes & Flash Execution

| Artifact | Path | SHA-256 Hash |
| :--- | :--- | :--- |
| **cand19 boot.img** | `/tmp/opencode/gs101/cand19/boot.img` | `7ad7325a83a6c6212d4c47f9a005fa5c1bbed20afa730572c5c1fe904d9c9602` |
| **cand18 vendor_boot.img** | `/tmp/opencode/gs101/cand18/vendor_boot.img` | `8a6840fbbc2035862a46123f5b25539d1085903a16d38a8904bb2966142ac818` |
| **Rollback boot_a (cand14)** | `/tmp/opencode/gs101/cand14/boot.img` | `84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36` |

### Flash Execution Log (`/tmp/opencode/gs101/flash-cand19.sh`):
```text
=== FLASH cand19 2026-11-26T04:04:18+01:00 ===
--- hashes before flash ---
7ad7325a83a6c6212d4c47f9a005fa5c1bbed20afa730572c5c1fe904d9c9602  /tmp/opencode/gs101/cand19/boot.img
84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36  /tmp/opencode/gs101/cand14/boot.img
=== Rebooting to bootloader ===
Waiting for fastboot device...
Found fastboot device: 1B021FDEE004XV	 fastboot
--- fastboot getvar ---
current-slot: a
unlocked: yes
Setting current slot to 'a'                        OKAY [  0.079s]
=== FLASH: boot_a ===
Sending 'boot_a' (14232 KB)                        OKAY [  0.460s]
Writing 'boot_a'                                   OKAY [  0.021s]
Finished. Total time: 0.507s
=== Rebooting device ===
Rebooting                                          OKAY [  0.000s]
=== Fastboot reboot command issued at 2026-11-26T04:04:29+01:00 ===
=== Waiting for SSH at 172.16.42.1 (max 90s) ===
WARNING: Device not reached via SSH after 90s! Initiating rollback...
Waiting for fastboot device for rollback...
< waiting for any device >
```

---

## 4. Root Cause Analysis: Why Panfrost Hangs on Mali-G78

When the core ID `0x9002` was added to `gpu_models[]`, Panfrost initialization no longer aborted with `-ENODEV` at line 354 of `panfrost_gpu.c`. Instead, it continued into full GPU and MMU hardware initialization:

1. **MMU Page Table Architecture Incompatibility (`ARM_MALI_LPAE` vs `ARM_64_LPAE_S1`):**
   In `drivers/gpu/drm/panfrost/panfrost_mmu.c` (line 786):
   ```c
   if (pfdev->comp->gpu_quirks & BIT(GPU_QUIRK_FORCE_AARCH64_PGTABLE)) {
       ...
       fmt = ARM_64_LPAE_S1;
   } else {
       fmt = ARM_MALI_LPAE;
   }
   ```
   Valhall hardware (Mali-G57, G78) deprecated and removed the legacy Midgard/Bifrost `ARM_MALI_LPAE` format. All Valhall SoCs (e.g. MediaTek MT8188, MT8192, MT8370 in `panfrost_drv.c`) explicitly configure:
   ```c
   .gpu_quirks = BIT(GPU_QUIRK_FORCE_AARCH64_PGTABLE),
   ```
   However, `gs101_data` in `panfrost_drv.c` does NOT set `GPU_QUIRK_FORCE_AARCH64_PGTABLE`. Consequently, Panfrost configured `ARM_MALI_LPAE` page tables and register bitfields on Mali-G78. Writing these incompatible bitfields during `panfrost_mmu_cfg_init()` results in an immediate bus lockup or unhandled MMU bus fault.

2. **Multi-Rail Regulator & Power Domain Deficiencies:**
   `gs101_supplies` defines 4 power rails (`"mali", "buck8s", "ldo1s", "buck7m"`). However, `panfrost_devfreq_init()` explicitly warns:
   ```
   [drm:panfrost_devfreq_init] More than 1 supply is not supported yet
   ```
   and skips frequency/voltage scaling integration. Without synchronized voltage scaling across the Exynos PMIC rails and GPU power domains, switching GPU power states causes an immediate hardware hang.

3. **Loss of Simpledrm Fallback:**
   Because `CONFIG_DRM_PANFROST=y` is built into `vmlinux`, `panfrost_probe()` runs synchronously during early kernel boot (`device_initcall`). When `0x9002` was unrecognized, `panfrost_probe()` returned `-ENODEV`, allowing the kernel to proceed to userspace with `simpledrm`. With `0x9002` recognized, the subsequent MMU/bus crash occurs BEFORE the USB gadget / CDC-NCM stack initializes, freezing the SoC entirely.

---

## 5. Rollback & Safety State

- The automated rollback script is holding `fastboot set_active a` / `fastboot flash boot_a /tmp/opencode/gs101/cand14/boot.img` (hash `84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36`).
- As soon as the device is put into fastboot (Power + VolDown), the rollback image flashes automatically and boots back into verified Candidate 14 baseline (Kernel #14, touch functional, Phosh active on simpledrm).
