# Vermagic Mismatch Analysis and Resolution (Option A)

**Date**: 2026-11-28  
**Scope**: Offline investigation and resolution of the kernel release `+` suffix mismatch between Candidate 20/21 kernel and `vendor_ramdisk00` touch driver (`sec_touch.ko`).

---

## 1. Problem Description & Regression Risk

During pre-flash offline verification for Candidate 21, a vermagic mismatch was identified:
- The initial `cand20` kernel Image was compiled with release string `7.3.0-rc6-gs101+` (with trailing `+`).
- The `vendor_boot` partition (`cand21` / `cand18` / `cand14`) contains `vendor_ramdisk00`, which bundles `sec_touch.ko` (Samsung touchscreen driver for Pixel 6 Pro raven) compiled with vermagic:
  ```text
  7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
  ```
  *(WITHOUT the `+` suffix)*.
- Target rootfs (`google-raven.img`) holds all base modules under:
  ```text
  /usr/lib/modules/7.3.0-rc6-gs101/
  ```

### Impact if Flashed Unresolved:
1. **Early Boot Touch Failure**: When initramfs executes `modprobe sec_touch` or `insmod sec_touch.ko`, the kernel module loader rejects the module:
   ```text
   sec_touch: version magic '7.3.0-rc6-gs101 SMP preempt mod_unload aarch64' should be '7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64'
   ```
   Touch input on the display would become completely non-functional.
2. **Userspace Module Path Failure**: System utilities and userspace tools lookup `/lib/modules/$(uname -r)/`. With `uname -r` returning `7.3.0-rc6-gs101+`, all directory accesses fail because `/usr/lib/modules/7.3.0-rc6-gs101+/` does not exist on rootfs.

---

## 2. Root Cause Analysis

The origin of the `+` suffix lies in `scripts/setlocalversion` within the Linux kernel build system:

```sh
# scripts/setlocalversion lines 201-210:
elif [ "${LOCALVERSION+set}" != "set" ]; then
	# If the variable LOCALVERSION is not set, append a plus
	# sign if the repository is not in a clean annotated or
	# signed tagged state (as git describe only looks at signed
	# or annotated tags - git tag -a/-s).
	#
	# If the variable LOCALVERSION is set (including being set
	# to an empty string), we don't want to append a plus sign.
	scm_version="$(scm_version --short)"
fi

echo "${KERNELVERSION}${file_localversion}${config_localversion}${LOCALVERSION}${scm_version}"
```

### Key Mechanisms:
1. In `.config`, `CONFIG_LOCALVERSION="-gs101"` and `# CONFIG_LOCALVERSION_AUTO is not set`.
2. When `LOCALVERSION` is unset in the environment or command line, `[ "${LOCALVERSION+set}" != "set" ]` evaluates to true.
3. Because the git tree commits are ahead of annotated release tags (or untagged), `scm_version --short` emits `+`.
4. When `cand14` and `cand18` were built, `LOCALVERSION=` was passed explicitly to `make` (documented in `Documentation/gs101/raven-boot-failure-analysis.md` line 338), ensuring `${LOCALVERSION+set}` was set and suppressing `+`.
5. When `cand20` was initially built, `LOCALVERSION=` was omitted from the `make` invocation, leading `scripts/setlocalversion` to append `+`.

---

## 3. Repair Options & Evaluation

### Option A: Rebuild Kernel with Empty LOCALVERSION (Selected & Executed)
- **Procedure**: Run `make ARCH=arm64 LLVM=1 LOCALVERSION="" Image.lz4 modules`.
- **Advantages**:
  - Restores exact `7.3.0-rc6-gs101` vermagic.
  - Matches `sec_touch.ko` in `vendor_ramdisk00` without modifying vendor boot ramdisk.
  - Matches rootfs directory `/usr/lib/modules/7.3.0-rc6-gs101/`.
  - `cand21 vendor_boot.img` hash (`43d5252a...`) remains completely unchanged and valid.
  - Zero regression risk to display, touch, or USB CDC-NCM networking.
- **Disadvantages**:
  - Requires kernel rebuild (completed cleanly on host).

### Option B: Keep `+` Kernel and Repack Vendor Ramdisk (Rejected)
- **Procedure**: Recompile `sec_touch.ko` with `+`, unpack `vendor_ramdisk00`, substitute module, repack into a new `cand22 vendor_boot.img`.
- **Disadvantages**:
  - Alters vendor ramdisk structure.
  - Breaks compatibility with target rootfs `/usr/lib/modules/7.3.0-rc6-gs101/`.
  - Invalidate previously verified `cand21 vendor_boot.img` SHA-256 hash.
  - Increases operational complexity with unnecessary regression surface.

---

## 4. Execution & Verification Evidence

### 4.1 Build Execution
Rebuilt cleanly on host with `LOCALVERSION=""`:
```bash
make ARCH=arm64 LLVM=1 LOCALVERSION="" -j8 Image.lz4 modules
```

### 4.2 Release String & Vermagic Parity
- `include/config/kernel.release`:
  ```text
  7.3.0-rc6-gs101
  ```
- Decompressed `arch/arm64/boot/Image`:
  ```text
  Linux version 7.3.0-rc6-gs101 (gregor@vmware007) (Ubuntu clang version 21.1.8) #17 SMP PREEMPT
  7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
  /lib/firmware/updates/7.3.0-rc6-gs101
  ```
- `drivers/gpu/drm/panfrost/panfrost.ko`:
  ```text
  vermagic=7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
  ```
- `drivers/gpu/drm/scheduler/gpu-sched.ko`:
  ```text
  vermagic=7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
  ```
- `drivers/bluetooth/hci_uart.ko`, `drivers/bluetooth/btbcm.ko`, `net/bluetooth/bluetooth.ko`:
  ```text
  vermagic=7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
  ```
- `vendor_ramdisk00` (`cand21` / `cand18` / `cand14` `sec_touch.ko`):
  ```text
  vermagic=7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
  ```

### 4.3 Static Inspection of Repacked `cand20 boot.img`
`cand20 boot.img` was repacked with header v4:
```bash
mkbootimg --header_version 4 --kernel arch/arm64/boot/Image.lz4 --output /tmp/opencode/gs101/cand20/boot.img
```
- Panfrost Modularity Audit:
  ```bash
  strings /tmp/opencode/gs101/cand20/unpacked/Image | grep -i panfrost | wc -l
  # Result: 0 occurrences (modularity 100% verified)
  ```
- Decompressed raw kernel size: 29,350,400 bytes.
- Header version: 4; OS version: None; Cmdline: empty; Ramdisk: 0 bytes.

---

## 5. Artifact Hash Matrix & Script Guard Synchronization

| Artifact | File Path | SHA-256 Hash | Status |
| :--- | :--- | :--- | :--- |
| **cand20 boot.img** | `/tmp/opencode/gs101/cand20/boot.img` | `4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9` | Rebuilt with `LOCALVERSION=""` |
| **panfrost.ko** | `/tmp/opencode/gs101/cand20/modules/panfrost.ko` | `562f9bc1f377a3f028182402c61439e128ca9e67efe2ecab8f1196f5e308a5c4` | Vermagic `7.3.0-rc6-gs101` |
| **gpu-sched.ko** | `/tmp/opencode/gs101/cand20/modules/gpu-sched.ko` | `eb00f25f5f61f9a3b70c6174781bf11878e35e67ec195d664bd6acb0af9967bf` | Vermagic `7.3.0-rc6-gs101` |
| **cand21 vendor_boot.img** | `/tmp/opencode/gs101/cand21/vendor_boot.img` | `43d5252a016b6b77fa4ed6164da097e84c0c2ce23eb9a9cd640e00209599daf4` | Unchanged, USI16 DTB + stock ramdisk |
| **cand14 boot.img** (Rollback) | `/tmp/opencode/gs101/cand14/boot.img` | `84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36` | Rollback reference |
| **cand18 vendor_boot.img** (Rollback) | `/tmp/opencode/gs101/cand18/vendor_boot.img` | `8a6840fbbc2035862a46123f5b25539d1085903a16d38a8904bb2966142ac818` | Rollback reference |

### Hash Guards in Flash Scripts:
- `/tmp/opencode/gs101/flash-cand20.sh`:
  - `EXPECT_CAND20="4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9"`
- `Documentation/gs101/evidence/issue11-gpu/flash-cand21.sh` & `/tmp/opencode/gs101/flash-cand21.sh`:
  - `EXPECT_CAND20_BOOT="4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9"`
  - `EXPECT_CAND21_VENDOR="43d5252a016b6b77fa4ed6164da097e84c0c2ce23eb9a9cd640e00209599daf4"`
  - `EXPECT_ROLLBACK_BOOT="84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36"`
  - `EXPECT_ROLLBACK_VENDOR="8a6840fbbc2035862a46123f5b25539d1085903a16d38a8904bb2966142ac818"`

Both scripts are verified and guarded against hash drifts.
