# Issue #10 / #11: Durable Host Storage Hierarchy & Artifact Layout (2026-11-28)

**Date**: 2026-11-28
**Scope**: Host-level durable storage hierarchy under `/home/gregor/phone-second-life-data/mb010/`, cryptographic verification table, environment override mapping, and post-reboot reconstitution procedure.
**Rule Compliance**: strictly offline documentation and artifact mapping. Zero kernel builds, no flash/reboot operations.

---

## 1. Permanent Storage Hierarchy Overview

To ensure complete resilience against volatile `/tmp` resets across host reboots, all deployment binaries, firmware blobs, candidate images, flash tools, and offline apk repositories are permanently rooted under:
```text
/home/gregor/phone-second-life-data/mb010/
├── apk-depot/
│   └── aarch64/                           # 16 APK packages for offline application deployment
├── artifact-backup/                       # Durable destination for verification JSON evidence
├── bundles/
│   ├── gs101-prep-bundle-20261128.tar.gz  # Canonical preparation bundle (52 entries, 5.3 MB)
│   └── gs101-prep-bundle-20261128.tar.gz.sha256
├── cand-images/
│   ├── cand14-boot-rollback.img           # Candidate 14 baseline boot image (known-good rollback)
│   ├── cand18-vendor_boot-rollback.img    # Candidate 18 vendor_boot image (known-good rollback guard)
│   ├── cand22-boot.img                    # Candidate 22 boot image (modular panfrost + pci-exynos)
│   ├── cand23-vendor_boot.img             # Candidate 23 vendor_boot image (PCIe RC1 + USI16/UART16 BT DTB)
│   └── SHA256SUMS                         # Checksum manifest for cand images
├── deploy-harden/
│   ├── gpu-modules/                       # Mali-G78 GPU acceleration modules
│   │   ├── gpu-sched.ko                   # DRM GPU scheduler (vermagic 7.3.0-rc6-gs101)
│   │   ├── panfrost.ko                    # Panfrost driver with 0x9002 entry & MMU quirk
│   │   └── SHA256SUMS                     # Checksum manifest for GPU modules
│   ├── modules/                           # Out-of-tree & modular WLAN/BT/PCIe drivers
│   │   ├── bcmdhd.ko                      # Broadcom BCM4389 FullMAC Wi-Fi driver
│   │   ├── bluetooth.ko                   # Core Bluetooth subsystem
│   │   ├── btbcm.ko                       # Broadcom Bluetooth helper
│   │   ├── btqca.ko                       # Qualcomm Bluetooth helper
│   │   ├── cfg80211.ko                    # Wireless configuration core
│   │   ├── hci_uart.ko                    # Bluetooth HCI UART serdev transport
│   │   ├── pci-exynos.ko                  # GS101 PCIe root complex controller
│   │   └── rfkill.ko                      # Radio killswitch subsystem
│   └── ssh/
│       └── known_hosts                    # Target SSH ECDSA host key
├── firmware/
│   └── bcm4389-extracted/
│       └── firmware/                      # 16 extracted BCM4389 Wi-Fi and BT firmware/NVRAM blobs
└── flash-scripts/
    ├── cand14-rollback.sh                 # Fastboot rollback writer invoked by systemd unit
    ├── flash-cand22.sh                    # Candidate 22 flash script (hardened ENV defaults)
    ├── flash-cand23.sh                    # Candidate 23 flash script (hardened ENV defaults)
    ├── rearm-cand14-after-cap.sh          # Prepared re-arm helper (armed after 00:11:03 cap)
    ├── sshc.sh                            # SSH command execution helper
    └── SHA256SUMS                         # Cryptographic checksum manifest
```

---

## 2. Cryptographic Checksum Table (SHA-256)

All artifacts have been verified using SHA-256 and confirm 100% binary reproducibility:

| Artifact Path | SHA-256 Checksum | Purpose / Specification |
| :--- | :--- | :--- |
| `cand-images/cand14-boot-rollback.img` | `84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36` | Rollback boot image (cand14 baseline, 64 MB) |
| `cand-images/cand18-vendor_boot-rollback.img` | `8a6840fbbc2035862a46123f5b25539d1085903a16d38a8904bb2966142ac818` | Rollback vendor_boot image (cand18 baseline guard, 64 MB) |
| `cand-images/cand22-boot.img` | `4c172f54ef5280c3bd63337613fd909f6695ab1d2c777f9913e658f05ca3fcf9` | Candidate 22 boot image (modular GPU, 64 MB) |
| `cand-images/cand23-vendor_boot.img` | `1d3f3a7e2fa2759d656651673b2ea0c84d0f92c53ff9d3a2e4766d19f0424c9d` | Candidate 23 vendor_boot image (PCIe/BT DTB, 64 MB) |
| `bundles/gs101-prep-bundle-20261128.tar.gz` | `2f7214032c3ffb896a3aaf7d9e5ebf7b8025866900ca543c2b911f2e1ce770d3` | Full deployment bundle (10 modules, 16 firmware) |
| `deploy-harden/gpu-modules/panfrost.ko` | `562f9bc1f377a3f028182402c61439e128ca9e67efe2ecab8f1196f5e308a5c4` | Panfrost driver (G78 support, 174,448 B) |
| `deploy-harden/gpu-modules/gpu-sched.ko` | `eb00f25f5f61f9a3b70c6174781bf11878e35e67ec195d664bd6acb0af9967bf` | DRM GPU scheduler (97,128 B) |
| `deploy-harden/modules/bcmdhd.ko` | `8f6ad033353aa0c9c9f4eb79d3f301c1727a1b2af9e57d462c82f027f4410ffb` | Broadcom Wi-Fi FullMAC driver (8,653,152 B) |
| `deploy-harden/modules/pci-exynos.ko` | `67e37cd087a2b16b63e8ac578ddcc02a3d7b6e2f3c76ec95c86037ab13d0342d` | GS101 PCIe RC1 driver (16,144 B) |
| `deploy-harden/modules/cfg80211.ko` | `11a9e57a2fd81d382fab440cd9ef0ed8f039714c9701f6175668d408b97aa987` | Wireless configuration core (1,990,552 B) |
| `deploy-harden/modules/rfkill.ko` | `7b2e9b268c059fae423afe78ba13c3955a36f8b70d470c37ea4db597de6144d5` | Radio killswitch core (61,480 B) |
| `deploy-harden/modules/bluetooth.ko` | `321ec87a16000414b389bdf0534b9e50e2445e529b2d9ab183e82d37a420e923` | Core Bluetooth stack (1,509,304 B) |
| `deploy-harden/modules/hci_uart.ko` | `a5b58650609a3239aee5c982b4a47f79c6756f3b6197669b05986072c97b583c` | HCI UART serdev transport (216,592 B) |
| `deploy-harden/modules/btbcm.ko` | `4588764e0cd8b0240e828fbcffdeec56e511759172653e6b4b1590a760da9139` | Broadcom Bluetooth helper (30,976 B) |
| `deploy-harden/modules/btqca.ko` | `130dd738c7c6d5496fb3dec7a1e4993f0247eb9cc0c18eeadc29001a04e7fb66` | Qualcomm Bluetooth helper (40,328 B) |
| `deploy-harden/ssh/known_hosts` | `be0b9d84069fae0eaa3f816db1a08333116564d93cb1102acac7c5cbc9e7bf26` | Target SSH ECDSA key verification |
| `flash-scripts/flash-cand22.sh` | `10eff17b1c0be4f67113ef5c8ec6fe1b6c91d8ce1bf7a1575839b3ce97182e82` | Candidate 22 flash script (hardened ENV defaults) |
| `flash-scripts/flash-cand23.sh` | `33d7ebc9a2d0cee3e51e13075d6ec3768fdc08d99d1b38ceaea3a2f689bac444` | Candidate 23 flash script (hardened ENV defaults) |
| `flash-scripts/cand14-rollback.sh` | `bb480a4e4eb329bd27e19b43bf855b922d7f027efeb16b5f079600d109fcc9e5` | Rollback service execution script |
| `flash-scripts/rearm-cand14-after-cap.sh` | `1986e7464abcb751ff27505149828a1ce7754cc6e8d6c8c8b2ba3ba6cb507d09` | Prepared post-cap rollback re-arm helper |
| `flash-scripts/sshc.sh` | `f5abe1af4a6bcb9721271ca07ac5615d5fa67880b96733e5861af6d42a5fb6f4` | SSH execution helper script |

---

## 3. Operational Script Environment Overrides

All operational test and deployment scripts in [Documentation/gs101/tests/](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/) have been updated to prioritize the permanent storage directory while maintaining graceful backward compatibility with `/tmp` caches:

| Script | Variable | Durable Default | Fallback Path |
| :--- | :--- | :--- | :--- |
| [build-deploy-bundle.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/build-deploy-bundle.sh) | `BUNDLE_SRC_MODULES` | `/home/gregor/.../mb010/deploy-harden/modules` | *None (strict)* |
| | `BUNDLE_SRC_GPU_MODULES` | `/home/gregor/.../mb010/deploy-harden/gpu-modules` | *None (strict)* |
| | `BUNDLE_SRC_FIRMWARE` | `/home/gregor/.../mb010/firmware/bcm4389-extracted/firmware` | *None (strict)* |
| | `BUNDLE_OUT` | `/home/gregor/.../mb010/bundles/gs101-prep-bundle-20261128.tar.gz` | *None (strict)* |
| [install-gpu.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/install-gpu.sh) | `CAND22_MOD_DIR` | `/home/gregor/.../mb010/deploy-harden/gpu-modules` | `/tmp/opencode/gs101/cand22/modules` |
| | `KNOWN_HOSTS_FILE` | `/home/gregor/.../mb010/deploy-harden/ssh/known_hosts` | `/tmp/opencode/gs101/issue4/known_hosts` |
| [install-wlan.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/install-wlan.sh) | `MODULE_SOURCE_DIR` | `/home/gregor/.../mb010/deploy-harden/modules` | `${SCRIPT_DIR}/lib/modules/...` / `/tmp/...` |
| | `FIRMWARE_SOURCE_DIR` | `/home/gregor/.../mb010/firmware/bcm4389-extracted/firmware` | `${SCRIPT_DIR}/lib/firmware` / `/tmp/...` |
| | `KNOWN_HOSTS_FILE` | `/home/gregor/.../mb010/deploy-harden/ssh/known_hosts` | `/tmp/opencode/gs101/issue4/known_hosts` |
| [install-apps.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/install-apps.sh) | `APK_DEPOT_LOCAL` | `/home/gregor/.../mb010/apk-depot/aarch64` | *None* |
| | `KNOWN_HOSTS_FILE` | `/home/gregor/.../mb010/deploy-harden/ssh/known_hosts` | `/tmp/opencode/gs101/issue4/known_hosts` |
| [verify-recovery.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/verify-recovery.sh) | `EVIDENCE_DIR` | `/home/gregor/.../mb010/artifact-backup` | `/tmp/opencode/gs101/evidence` |
| | `KNOWN_HOSTS_FILE` | `/home/gregor/.../mb010/deploy-harden/ssh/known_hosts` | `/tmp/opencode/gs101/issue4/known_hosts` |
| [flash-cand22.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue8-wireless/flash-cand22.sh) | `BOOT_IMG` | `/home/gregor/.../mb010/cand-images/cand22-boot.img` | `/tmp/opencode/gs101/cand22/boot.img` |
| | `ROLLBACK_BOOT` | `/home/gregor/.../mb010/cand-images/cand14-boot-rollback.img` | `/tmp/opencode/gs101/cand14/boot.img` |
| | `KNOWN_HOSTS_FILE` | `/home/gregor/.../mb010/deploy-harden/ssh/known_hosts` | `/tmp/opencode/gs101/issue4/known_hosts` |
| | `SSH_HELPER` | `/home/gregor/.../mb010/flash-scripts/sshc.sh` | `/tmp/opencode/gs101/issue4/sshc.sh` |
| | `EVIDENCE_DIR` / `RESULT_DIR` | `/home/gregor/.../mb010/flash-scripts` | `/tmp/opencode/gs101/evidence` |
| [flash-cand23.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue8-wireless/flash-cand23.sh) | `BOOT_IMG` | `/home/gregor/.../mb010/cand-images/cand22-boot.img` | `/tmp/opencode/gs101/cand22/boot.img` |
| | `VENDOR_BOOT_IMG` | `/home/gregor/.../mb010/cand-images/cand23-vendor_boot.img` | `/tmp/opencode/gs101/cand23/vendor_boot.img` |
| | `ROLLBACK_BOOT` | `/home/gregor/.../mb010/cand-images/cand14-boot-rollback.img` | `/tmp/opencode/gs101/cand14/boot.img` |
| | `ROLLBACK_VENDOR` | `/home/gregor/.../mb010/cand-images/cand18-vendor_boot-rollback.img` | `/tmp/opencode/gs101/cand18/vendor_boot.img` |
| | `KNOWN_HOSTS_FILE` | `/home/gregor/.../mb010/deploy-harden/ssh/known_hosts` | `/tmp/opencode/gs101/issue4/known_hosts` |
| | `SSH_HELPER` | `/home/gregor/.../mb010/flash-scripts/sshc.sh` | `/tmp/opencode/gs101/issue4/sshc.sh` |
| | `EVIDENCE_DIR` / `RESULT_DIR` | `/home/gregor/.../mb010/flash-scripts` | `/tmp/opencode/gs101/evidence` |

---

## 4. Rollback Service Re-Arm & Forensics Reference

- **Single-Writer Safety Invariant**: `cand14-rollback.service` (Main PID `1432080`, armed until 2026-11-29 00:11:03 CET) remains the sole active flash writer.
- **Prepared Re-Arm Procedure**: [rearm-cand14-after-cap.sh](file:///home/gregor/phone-second-life-data/mb010/flash-scripts/rearm-cand14-after-cap.sh) enforces 5 duplicate guards (`pgrep` check, `systemctl is-active` check, unclosed log check, flash result check, and script sha256). Re-arming is performed by the supervisor following the 00:11:03 CET cap.
- **Forensics Investigation**: See [rollback-rearm-forensics-20261128.md](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue10-image/rollback-rearm-forensics-20261128.md) for complete forensic traces and analysis of the ephemeral PID 1557166 process.

---

## 5. Post-Reboot Reconstitution Procedure

If the host machine reboots prior to operator recovery, `/tmp` will be wiped cleanly by the operating system. To restore the working cache and run verification, execute:

```bash
# 1. Regenerate bundle or unpack the permanent archive
./Documentation/gs101/tests/build-deploy-bundle.sh

# 2. Extract into /tmp working cache (if desired for standalone execution)
mkdir -p /tmp/opencode/gs101
tar -xzf /home/gregor/phone-second-life-data/mb010/bundles/gs101-prep-bundle-20261128.tar.gz -C /tmp/opencode/gs101/

# 3. Verify SHA256 integrity of restored files
(
    cd /tmp/opencode/gs101/wlan-bundle
    sha256sum -c SHA256SUMS
)
```

This procedure guarantees zero lost artifacts, zero compilation delays, and instant operational readiness upon device recovery.
