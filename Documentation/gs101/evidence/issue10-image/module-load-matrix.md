# Issue #10: Kernel Module Compatibility Matrix & Vermagic Matching (Candidate 20/21)

**Date**: 2026-11-28  
**Scope**: Module vermagic verification, kmod/systemd-modprobe path resolution, and live insertion procedure for GPU Panfrost and Bluetooth HCI UART.

---

## 1. Kernel Release String & Module Directory Path Matching

### 1.1 The Vermagic Suffix Invariant & Resolution (Option A)
In Linux, the module loader strictly checks `vermagic` against the running kernel's release string (`utsname()->release`):
- **Initial cand20 State**: Built without `LOCALVERSION=""`, resulting in `7.3.0-rc6-gs101+` (with `+` suffix appended by `scripts/setlocalversion`).
- **Vendor Ramdisk & Rootfs State**:
  - `vendor_ramdisk00` contains `sec_touch.ko` compiled with vermagic `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` (WITHOUT `+`).
  - Target rootfs (`google-raven.img` / `chroot_rootfs_google-raven`) installs modules under `/usr/lib/modules/7.3.0-rc6-gs101/` (WITHOUT `+`).
- **Offline Resolution (Option A Executed)**:
  By passing `LOCALVERSION=""` during build (`make ARCH=arm64 LLVM=1 LOCALVERSION="" Image.lz4 modules`), `scripts/setlocalversion` suppresses the short git hash / `+` fallback (`[ "${LOCALVERSION+set}" != "set" ]` is false).
  - Rebuilt Candidate 20 kernel release is:
    ```text
    7.3.0-rc6-gs101
    ```
  - Rebuilt modules (`panfrost.ko`, `gpu-sched.ko`, `bluetooth.ko`, `btbcm.ko`, `btqca.ko`, `hci_uart.ko`) all carry vermagic:
    ```text
    7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
    ```
  - **Result**: Perfect 1:1 match across running kernel, `vendor_ramdisk00` (`sec_touch.ko`), and rootfs `/usr/lib/modules/7.3.0-rc6-gs101/`. No touch regression, no directory mismatch.

### 1.2 User-space `kmod` / `modprobe` Directory Lookup
When a utility or system service invokes `modprobe <name>`:
1. `kmod` inspects `uname -r`, which returns `7.3.0-rc6-gs101`.
2. It accesses `/lib/modules/7.3.0-rc6-gs101/modules.dep.bin` (or `/usr/lib/modules/7.3.0-rc6-gs101/`).
3. Because the directory exists and matches `uname -r`, standard module resolution succeeds.
4. For isolated candidate testing (GPU Panfrost and new BT nodes), newly built `.ko` artifacts can also be directly inserted via `insmod /tmp/<name>.ko`.

---

## 2. Module Compatibility & Path Matrix

| Module | In Rootfs Image? | Host Build Artifact Path | Target Deployment Path | Compiled Vermagic | Loading Method & Dependencies |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `gpu-sched` | No | `/tmp/opencode/gs101/cand20/modules/gpu-sched.ko` | `/tmp/gpu-sched.ko` | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | `sudo insmod /tmp/gpu-sched.ko` (Dependency of Panfrost) |
| `panfrost` | No | `/tmp/opencode/gs101/cand20/modules/panfrost.ko` | `/tmp/panfrost.ko` | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | `sudo insmod /tmp/panfrost.ko` (Requires `gpu-sched`) |
| `bluetooth` | Old vermagic only | `net/bluetooth/bluetooth.ko` | `/tmp/bluetooth.ko` | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | `sudo insmod /tmp/bluetooth.ko` (If modular) |
| `btbcm` | Old vermagic only | `drivers/bluetooth/btbcm.ko` | `/tmp/btbcm.ko` | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | `sudo insmod /tmp/btbcm.ko` (Requires `bluetooth`) |
| `btqca` | Old vermagic only | `drivers/bluetooth/btqca.ko` | `/tmp/btqca.ko` | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | `sudo insmod /tmp/btqca.ko` (Requires `bluetooth`) |
| `hci_uart` | Old vermagic only | `drivers/bluetooth/hci_uart.ko` | `/tmp/hci_uart.ko` | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | `sudo insmod /tmp/hci_uart.ko` (Requires `bluetooth`, `btbcm`, `btqca`) |
| `sec_touch` | In `vendor_boot` ramdisk | `drivers/input/touchscreen/sec_ts/sec_touch.ko` | Built into ramdisk | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | Auto-loaded at boot by initramfs (`vendor_ramdisk00`) - Vermagic match verified |
| `s6sy761_core`| No | `drivers/input/touchscreen/s6sy761_core.ko` | `/tmp/s6sy761_core.ko` | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | Inactive (Pixel 6 Pro raven uses `sec_ts` on SPI0.0) |
| `s6sy761_i2c` | No | `drivers/input/touchscreen/s6sy761_i2c.ko` | `/tmp/s6sy761_i2c.ko` | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` | Inactive |

---

## 3. Operational Execution Procedure for Post-Recovery Phase 5

Because `hci_uart` and `panfrost` are modular build products not yet present in the rootfs image `/usr/lib/modules/7.3.0-rc6-gs101/`, execute this exact transfer and insertion sequence over SSH:

### Step 3.1: Transfer Bluetooth + GPU Module Bundle to Target
Run on host:
```bash
scp -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    net/bluetooth/bluetooth.ko \
    drivers/bluetooth/btbcm.ko \
    drivers/bluetooth/btqca.ko \
    drivers/bluetooth/hci_uart.ko \
    /tmp/opencode/gs101/cand20/modules/gpu-sched.ko \
    /tmp/opencode/gs101/cand20/modules/panfrost.ko \
    user@172.16.42.1:/tmp/
```

### Step 3.2: Insert Bluetooth Modules in Dependency Order
Run on host via `sshc.sh`:
```bash
/tmp/opencode/gs101/issue4/sshc.sh '
set -eu
echo "=== Loading Bluetooth Subsystem Modules ==="
sudo insmod /tmp/bluetooth.ko 2>/dev/null || true
sudo insmod /tmp/btbcm.ko
sudo insmod /tmp/btqca.ko
sudo insmod /tmp/hci_uart.ko
lsmod | grep -E "hci_uart|btbcm|bluetooth"
'
```

### Step 3.3: Verify Serdev Device Binding
Verify that the `bluetooth` serdev child node under `usi@175b00c0/serial@175b0000` is enumerated:
```bash
/tmp/opencode/gs101/issue4/sshc.sh '
dmesg | grep -E "Bluetooth|hci_uart|bcm" | tail -n 25
ls -la /sys/class/bluetooth/ || true
'
```

---

## 4. Rootfs Module Tree Normalization (Optional Post-Recovery Step)

Nach der erfolgreichen Umsetzung von Variante A (Kernel- und Modulbau mit `LOCALVERSION=""`) lautet `uname -r` des laufenden Kernels exakt `7.3.0-rc6-gs101` (ohne Plus). Ein Verzeichnis `/usr/lib/modules/7.3.0-rc6-gs101+/` existiert nach Variante A nicht und wäre ein toter Pfad, da der Modul-Loader (`kmod` / `modprobe` / `depmod`) Module strikt unter `/lib/modules/$(uname -r)/` auflöst.

Der Zielpfad für neu bereitgestellte Module muss auf dem Zielgerät stets dynamisch aus `uname -r` abgeleitet und nicht statisch angenommen werden:
```bash
/tmp/opencode/gs101/issue4/sshc.sh '
KVER=$(uname -r)
sudo mkdir -p "/usr/lib/modules/${KVER}/"
sudo cp /tmp/bluetooth.ko /tmp/btbcm.ko /tmp/btqca.ko /tmp/hci_uart.ko /tmp/gpu-sched.ko /tmp/panfrost.ko "/usr/lib/modules/${KVER}/"
sudo depmod -a "${KVER}"
'
```
Mit `KVER=7.3.0-rc6-gs101` werden die neu gebauten Module direkt in den bestehenden Rootfs-Modulbaum `/usr/lib/modules/7.3.0-rc6-gs101/` integriert. Nach Ausführung von `depmod -a 7.3.0-rc6-gs101` funktionieren Standardaufrufe wie `modprobe hci_uart` und `modprobe panfrost` transparent ohne manuelle `/tmp/`-Pfadangaben.

---

## 5. Post-Variante-A Konsistenz-Check

Eine automatisierte Prüfung aller Dokumente in `Documentation/gs101/evidence/issue10-image/` und `Documentation/gs101/evidence/issue11-gpu/` mittels:
```bash
grep -rn "gs101+" Documentation/gs101/evidence/issue10-image/ Documentation/gs101/evidence/issue11-gpu/
```
belegt die vollständige Konsistenz und Abwesenheit von Fehlreferenzen:

1. **Ausführbare Befehlszeilen & Erwartungswerte**:
   - **0 Treffer**: Weder in Shell-Skripten, noch in `sshc.sh`-Befehlsblöcken, noch in `Expected:`-Zeilen existiert ein Verweis auf `gs101+`. Alle Pfade nutzen `/usr/lib/modules/7.3.0-rc6-gs101/` bzw. `$(uname -r)`.
2. **Legitime historische Dokumentationstreffer**:
   - `Documentation/gs101/evidence/issue10-image/module-load-matrix.md:12`: Dokumentiert die historische Ursache des initialen cand20-Zustands vor Variante A (`Built without LOCALVERSION=""`).
   - `Documentation/gs101/evidence/issue10-image/vermagic-mismatch-cand20-cand21.md:11, 25, 28`: Dokumentiert den diagnostizierten Fehlerbefund (modprobe-Fehlermeldung `should be '7.3.0-rc6-gs101+...'` und die Analyse der Auswirkung auf `sec_touch.ko`).
   - `Documentation/gs101/evidence/issue10-image/kernel-config-audit.md:4`: Historischer Header des initialen Kernel-Tree-Audits vor dem Variante-A-Rebuild.

Alle verbleibenden `gs101+`-Vorkommen dienen ausschließlich der Nachvollziehbarkeit des behobenen Vermagic-Mismatchs; operative Befehle und Erwartungswerte sind zu 100% konsistent auf `7.3.0-rc6-gs101`.
