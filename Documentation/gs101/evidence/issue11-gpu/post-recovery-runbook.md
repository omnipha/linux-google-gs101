# Post-Recovery Runbook: Candidate 14 Baseline & Candidate 20 Panfrost Isolation

This runbook defines the exact, sequential procedure to execute immediately upon device recovery following physical operator force-off (Power + Volume Down) into fastboot mode.

---

## Pre-Conditions & Invariants

1. **Active Rollback Unit**:
   `systemd --user Unit cand14-rollback.service` (Main PID 1432080) is currently armed and waiting for fastboot devices.
   - When the operator forces the device into fastboot, the unit flashes `cand14` `boot_a` (SHA-256: `84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36`), sets slot `a`, and reboots.
   - **Do NOT run any flash commands** while the unit is armed or waiting.

2. **Network Setup on Host**:
   Once the device boots, USB CDC-NCM appears as `enx*` on the host:
   ```bash
   for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^enx'); do
       sudo ip addr add 172.16.42.2/24 dev "$iface" 2>/dev/null || true
       sudo ip link set "$iface" up 2>/dev/null || true
   done
   ```

---

## Phase 1: SSH Return & Candidate 14 Baseline Verification

### Step 1.1: Verify SSH Connectivity
```bash
ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
    user@172.16.42.1 'echo ONLINE'
```

### Step 1.2: Verify Candidate 14 Kernel Baseline
Execute on device over SSH:
```bash
# 1. Kernel version
uname -a
# Expected: Linux postmarketos 7.3.0-rc6-gs101 #14 SMP PREEMPT ... aarch64

# 2. Command line and console verification
cat /proc/cmdline
# Expected: Ends with '... console=tty0 fbcon=font:TER16x32 ...'

cat /proc/consoles
# Expected: tty0 -WU (active system console)

# 3. GPU state in dmesg (cand14 baseline: GPU model not found due to missing 0x9002 entry)
dmesg | grep -E "panfrost|gpu|mali"

# 4. Display & DRM nodes
ls -la /dev/dri/
# Expected: card0 present (simpledrm); renderD128 absent
```

### Step 1.3: Document Rollback Verification in Issue #11
- Reference rollback log: `/tmp/opencode/gs101/evidence/rollback-cand14-*.log`
- Document `ctx:UE` failure pattern of cand19 and confirm recovery on cand14 baseline.

---

## Phase 2: Live Panfrost Module Test on Candidate 14 Baseline

Before flashing any new kernel `boot_a`, verify `panfrost.ko` (built with G78 entry `7192a3afa` and AArch64 MMU quirk `6222239f2`) via live module loading.

### Step 2.1: Transfer Module Artifacts to Device
```bash
scp -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    /tmp/opencode/gs101/cand20/modules/gpu-sched.ko \
    /tmp/opencode/gs101/cand20/modules/panfrost.ko \
    user@172.16.42.1:/tmp/
```

### Step 2.2: Live Module Insertion
```bash
# 1. Insert DRM scheduler dependency
ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    user@172.16.42.1 'sudo insmod /tmp/gpu-sched.ko'

# 2. Insert Panfrost driver
ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    user@172.16.42.1 'sudo insmod /tmp/panfrost.ko'
```

### Step 2.3: Evaluate Kernel Log & DRM Nodes
```bash
# Inspect dmesg output for Panfrost probe
ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    user@172.16.42.1 'dmesg | grep -E "panfrost|mali|gpu" | tail -n 30'

# Check DRM devices
ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    user@172.16.42.1 'ls -la /dev/dri/'
```

**Evaluation Criteria**:
- **Success Criteria**:
  - `panfrost 1c500000.gpu: mali-g78 id 0x9002 major 0x...` successfully recognized.
  - No MMU faults or bus lockups.
  - `/dev/dri/renderD128` is created!
- **Fault Handling**:
  - If `insmod` returns an error or oops, capture the verbatim oops from `dmesg`. Because Panfrost is modular, userspace and SSH remain responsive. Document trace in Issue #11.

---

## Phase 3: Candidate 22/23 Flash Execution (Supervisor Authorized Consolidated Path)

**Precondition**: Execute ONLY AFTER Phase 2 live module test completes and supervisor authorizes kernel/vendor flash.

> [!IMPORTANT]
> **Phase 3 GPU Userspace Validation Note (Issue #11 Panfrost Proof)**:
> After Panfrost probing (confirming `/dev/dri/renderD128` exists), install the Gallium3D driver and verification utilities from the offline APK depot (`/tmp/apk-depot`):
> ```bash
> sudo apk add --allow-untrusted --repository /tmp/apk-depot \
>     mesa-dri-gallium mesa-utils mesa-demos
> ```
> Execute proof commands on target:
> 1. Verify OpenGL/EGL renderer string:
>    ```bash
>    eglinfo -B | grep -E "(OpenGL vendor|OpenGL renderer|OpenGL version)"
>    ```
>    *Required evidence*: `renderD128` bound to `Mali-G78 (Panfrost)`.
> 2. Execute Wayland GLES2 test:
>    ```bash
>    WAYLAND_DISPLAY=wayland-0 es2gears_wayland
>    ```
> Without `mesa-dri-gallium` (`/usr/lib/dri/panfrost_dri.so`), `WLR_RENDERER=gles2` in Phoc will fail or fall back to software rendering (`llvmpipe`), regardless of `panfrost.ko` loading cleanly.

### Why `vendor_boot` Flash is Required for Bluetooth & Wi-Fi (Issue #8)
In Android boot header v4, the kernel Device Tree (`DTB`) is delivered by the bootloader from the `vendor_boot` partition (`dtb` region), **not** from `boot.img`.
- The on-device `vendor_boot_a` (`cand18`, SHA-256 `8a6840fb...`) carries an older DTB (`82ae6a8a...`) that predates Bluetooth and PCIe DTS implementations.
- To enable GPU Panfrost modular testing (Issue #11), PCIe RC1 root complex activation, and Bluetooth serdev probing (Issue #8) in one consolidated deployment, **Candidate 23** updates both partitions:
  - `boot_a`: `cand22` `boot.img` (modular Panfrost + `CONFIG_PCI_EXYNOS=m`)
  - `vendor_boot_a`: `cand23` `vendor_boot.img` (DTB containing `pcie@14520000` + `usi@175b00c0`/`serial@175b0000`)

### Step 3.1: Verify Rollback Unit is Inactive
Ensure `cand14-rollback.service` is no longer active:
```bash
systemctl --user is-active cand14-rollback.service
# Must be 'inactive' or 'failed' (completed), NOT running.
```

### Step 3.2: Execute Consolidated Candidate 23 Flash Script
Run the prepared single-shot flash script:
```bash
/tmp/opencode/gs101/flash-cand23.sh
```
- Flashes `cand22` `boot_a` + `cand23` `vendor_boot_a`.
- Reboots device into Candidate 23.
- Structured JSON output written to `/tmp/opencode/gs101/evidence/flash-cand23-*.json`.
- *(Fallback / Isolation paths)*:
  - `/tmp/opencode/gs101/flash-cand20.sh` (isolated GPU `boot_a` only)
  - `/tmp/opencode/gs101/flash-cand21.sh` (GPU + BT DTB without PCIe RC1)
  - `/tmp/opencode/gs101/flash-cand22.sh` (`cand22` `boot_a` only)

---

## Phase 4: Candidate 22/23 Boot Verification, GPU Acceleration & WLAN/BT Staging

### Step 4.1: Verify Candidate 22/23 Boot & Simpledrm Display
```bash
ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    user@172.16.42.1 'uname -a; cat /proc/cmdline; ls -la /dev/dri/'
```
- Confirm kernel boots cleanly on `simpledrm` with zero Panfrost early-boot involvement.

### Step 4.2: Load Panfrost Modules
```bash
ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    user@172.16.42.1 'sudo insmod /tmp/gpu-sched.ko && sudo insmod /tmp/panfrost.ko'
```
- Verify `/dev/dri/renderD128` exists.

### Step 4.3: Test Phoc Hardware Acceleration (`WLR_RENDERER=gles2`)
1. Configure Phoc renderer override:
   ```bash
   ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
       user@172.16.42.1 'sudo mkdir -p /etc/systemd/system/phosh.service.d && echo -e "[Service]\nEnvironment=WLR_RENDERER=gles2" | sudo tee /etc/systemd/system/phosh.service.d/override.conf && sudo systemctl daemon-reload && sudo systemctl restart phosh'
   ```
2. Verify Phoc log and hardware acceleration:
   ```bash
   ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
       user@172.16.42.1 'journalctl -u phosh -n 50 --no-pager | grep -i renderer'
   ```
3. Capture screen via `grim`:
   ```bash
   ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
       user@172.16.42.1 'grim /tmp/phosh-gles2.png'
   scp -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
       user@172.16.42.1:/tmp/phosh-gles2.png /tmp/opencode/gs101/evidence/issue11-gpu/
   ```

---

## Phase 5: Issue #10 Application Minimal Set & Persistence Verification

*Hinweis zu Modulpfaden*: Nach Umsetzung von Variante A lautet `uname -r` exakt `7.3.0-rc6-gs101` (ohne Plus). Alle systemweiten Modulpfade in den Befehlszeilen und kmod/modprobe-Konfigurationen zeigen daher auf `/usr/lib/modules/7.3.0-rc6-gs101/` (ohne Plus), damit Phase 5 und systemd-Dienste nicht ins Leere laufen.

Once GPU acceleration is verified:
1. Verify reboot persistence of network routing (default via `172.16.42.2`) and DNS (`1.1.1.1`).
2. Verify pre-installed applications (`lxterminal`, `foot`).
3. Install file manager (`pcmanfm`) and calculator (`gnome-calculator` / PMOS alternative) via `apk`.
4. Document full application inventory and reboot persistence state in `Documentation/gs101/evidence/issue10-image/`.
