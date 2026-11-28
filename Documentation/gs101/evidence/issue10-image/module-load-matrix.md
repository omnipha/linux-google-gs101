# Issue #10: Kernel Module Compatibility Matrix & Vermagic Matching (Candidate 20/21)

**Date**: 2026-11-28  
**Scope**: Module vermagic verification, kmod/systemd-modprobe path resolution, and live insertion procedure for GPU Panfrost and Bluetooth HCI UART.

---

## 1. Kernel Release String & Module Directory Path Matching

### 1.1 The Vermagic Suffix Invariant
In Linux, the module loader strictly checks `vermagic` against the running kernel's release string (`utsname()->release`):
- **Candidate 20/21 Kernel Release**: `include/config/kernel.release` contains:
  ```text
  7.3.0-rc6-gs101+
  ```
  *(The `+` suffix is appended by `scripts/setlocalversion` because git commits are ahead of base tag)*.
- **Rootfs Baseline Directory**:
  In the target rootfs image (`google-raven.img` / `chroot_rootfs_google-raven`), modules were installed under:
  ```text
  /usr/lib/modules/7.3.0-rc6-gs101/
  ```
  *(WITHOUT the `+` suffix, built from an earlier non-plus kernel baseline)*.

### 1.2 User-space `kmod` / `modprobe` Directory Lookup
When a utility or system service invokes `modprobe <name>`:
1. `kmod` inspects `uname -r`, which returns `7.3.0-rc6-gs101+`.
2. It attempts to open `/lib/modules/7.3.0-rc6-gs101+/modules.dep.bin` (or `/usr/lib/modules/7.3.0-rc6-gs101+/`).
3. If `/lib/modules/7.3.0-rc6-gs101+/` does not exist:
   ```text
   modprobe: can't change directory to '/lib/modules/7.3.0-rc6-gs101+': No such file or directory
   ```
4. Even if `/lib/modules/7.3.0-rc6-gs101` were symlinked, any module from that tree would be rejected by the kernel module loader:
   ```text
   version magic '7.3.0-rc6-gs101 SMP preempt mod_unload aarch64' should be '7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64'
   ```

**Architectural Conclusion**:
All runtime-loaded modules for Candidate 20/21 (`panfrost`, `gpu-sched`, `hci_uart`, `btbcm`, `btqca`, `bluetooth`) must be loaded from our freshly built `7.3.0-rc6-gs101+` artifact set via direct `insmod` or deployed into a matching `/lib/modules/7.3.0-rc6-gs101+/` directory.

---

## 2. Module Compatibility & Path Matrix

| Module | In Rootfs Image? | Host Build Artifact Path | Target Deployment Path | Compiled Vermagic | Loading Method & Dependencies |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `gpu-sched` | No | `/tmp/opencode/gs101/cand20/modules/gpu-sched.ko` | `/tmp/gpu-sched.ko` | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | `sudo insmod /tmp/gpu-sched.ko` (Dependency of Panfrost) |
| `panfrost` | No | `/tmp/opencode/gs101/cand20/modules/panfrost.ko` | `/tmp/panfrost.ko` | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | `sudo insmod /tmp/panfrost.ko` (Requires `gpu-sched`) |
| `bluetooth` | Old vermagic only | `net/bluetooth/bluetooth.ko` | `/tmp/bluetooth.ko` | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | `sudo insmod /tmp/bluetooth.ko` (If modular) |
| `btbcm` | Old vermagic only | `drivers/bluetooth/btbcm.ko` | `/tmp/btbcm.ko` | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | `sudo insmod /tmp/btbcm.ko` (Requires `bluetooth`) |
| `btqca` | Old vermagic only | `drivers/bluetooth/btqca.ko` | `/tmp/btqca.ko` | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | `sudo insmod /tmp/btqca.ko` (Requires `bluetooth`) |
| `hci_uart` | Old vermagic only | `drivers/bluetooth/hci_uart.ko` | `/tmp/hci_uart.ko` | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | `sudo insmod /tmp/hci_uart.ko` (Requires `bluetooth`, `btbcm`, `btqca`) |
| `sec_touch` | In `vendor_boot` ramdisk | `drivers/input/touchscreen/sec_ts/sec_touch.ko` | Built into ramdisk | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | Auto-loaded at boot by initramfs (`vendor_ramdisk00`) |
| `s6sy761_core`| No | `drivers/input/touchscreen/s6sy761_core.ko` | `/tmp/s6sy761_core.ko` | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | Inactive (Pixel 6 Pro raven uses `sec_ts` on SPI0.0) |
| `s6sy761_i2c` | No | `drivers/input/touchscreen/s6sy761_i2c.ko` | `/tmp/s6sy761_i2c.ko` | `7.3.0-rc6-gs101+ SMP preempt mod_unload aarch64` | Inactive |

---

## 3. Operational Execution Procedure for Post-Recovery Phase 5

Because `hci_uart` and its dependencies in the rootfs cannot be loaded via `modprobe` on a `+` kernel, execute this exact transfer and insertion sequence over SSH:

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

To allow standard `modprobe` and `depmod` to function normally on Candidate 20/21:
```bash
/tmp/opencode/gs101/issue4/sshc.sh '
sudo mkdir -p /usr/lib/modules/7.3.0-rc6-gs101+/
sudo cp /tmp/bluetooth.ko /tmp/btbcm.ko /tmp/btqca.ko /tmp/hci_uart.ko /tmp/gpu-sched.ko /tmp/panfrost.ko /usr/lib/modules/7.3.0-rc6-gs101+/
sudo depmod -a 7.3.0-rc6-gs101+
'
```
Once normalized, `modprobe hci_uart` and `modprobe panfrost` will function without requiring `/tmp/` paths.
