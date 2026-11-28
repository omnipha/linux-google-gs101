# Offline aarch64 APK Depot (Issue #5 / #10 Phase 5)

**Date**: 2026-11-28  
**Depot Location (Host)**: `/home/gregor/phone-second-life-data/mb010/apk-depot/aarch64/`  
**Target Environment**: postmarketOS edge (aarch64), systemd init, Phosh UI  
**Target Device**: Google Pixel 6 Pro (`raven`, GS101 SoC)  

---

## 1. Overview & Policy

Because DNS resolution on the device is currently broken and the USB CDC-NCM NAT uplink may not be immediately available during early recovery, this offline package depot provides a fully self-contained transitive dependency closure for the requested minimal application set.

### Operating Context:
- **When Depot is used**: Used immediately if target DNS resolution (`dl-cdn.alpinelinux.org` HTTP lookup) or NAT masquerade fails during post-recovery Phase 5. The depot eliminates all external network dependencies and guarantees reproducible offline package installation over SSH / SCP.
- **When NAT-DNS-Fix is used**: Used once basic connectivity and the persistent `unudhcpd@usb0` default route + `systemd-resolved` DNS override are verified for long-term system maintenance.
- **Repository Cleanliness Policy**: No binary package files, database files, or index archives are committed to the git repository. All packages reside strictly in `/home/gregor/phone-second-life-data/mb010/apk-depot/`.

---

## 2. Depot Inventory & Summary

- **Total Packages in Closure**: 263 `.apk` files
- **Total APK Payload Size**: 190.50 MB
- **Simulated Installation Size**: 545.3 MiB in 262 packages
- **File System Permissions**: Directories `0755`, Files `0644`
- **Integrity & Provenance**:
  - `SHA256SUMS`: Full cryptographic checksums across all 270 files (263 APKs, 4 upstream index tarballs, 2 local index tarballs, `urls.txt`).
  - `urls.txt`: Exact official CDN/mirror provenance URL for each of the 263 packages (100% resolved from official Alpine/postmarketOS mirrors).

### Target Application Versions:
| Package | Version | Primary Capabilities & Stack | Upstream Source |
| :--- | :--- | :--- | :--- |
| `foot` | `1.28.0-r0` | Fast, lightweight native Wayland terminal | Alpine Linux `edge/community` |
| `lxterminal` | `0.4.0-r2` | Proven GTK+3 / VTE terminal emulator | Alpine Linux `edge/community` |
| `pcmanfm` | `1.4.0-r0` | Fast, touch-friendly file manager (libfm / GTK3) | Alpine Linux `edge/community` |
| `galculator` | `2.1.4-r5` | GTK+3 scientific calculator | Alpine Linux `edge/community` |
| `gnome-calculator` | `51.1-r0` | Adaptive mobile calculator (GTK4 / Libadwaita) | Alpine Linux `edge/community` |
| `mesa-dri-gallium` | `26.3.1-r0` | Panfrost Gallium3D driver (`panfrost_dri.so`) | Alpine Linux `edge/main` |
| `mesa-utils` | `9.0.0-r6` | EGL/GL diagnostic utilities (`eglinfo`, `glxinfo`) | Alpine Linux `edge/community` |
| `mesa-demos` | `9.0.0-r6` | GLES2/EGL render verification (`es2gears_wayland`) | Alpine Linux `edge/community` |

### Included Upstream Dependency Layers:
- **Core Desktop & Graphics**: `mesa` (26.3.1-r0), `mesa-dri-gallium`, `mesa-egl`, `mesa-gbm`, `mesa-gl`, `mesa-gles`, `wayland-libs`, `vulkan-loader`, `libdrm`, `cairo`, `pango`, `harfbuzz`, `fontconfig`, `freetype`.
- **UI Toolkits & Graphics Helpers**: `gtk+3.0` (3.24.52-r0), `gtk4.0` (4.24.2-r0), `libadwaita` (1.10.0-r0), `vte3` (0.85.0-r0), `freeglut`, `glu`, `libdecor`.
- **Audio & Media Frameworks**: `gstreamer`, `gst-plugins-base`, `gst-plugins-bad`, `alsa-lib`, `libpulse`/`soundtouch`.
- **System Integration**: `dbus-systemd`, `dbus-libs`, `systemd-libs`, `at-spi2-core-systemd`, `shared-mime-info`, `hicolor-icon-theme`.

---

## 3. GPU Userspace Stack (Issue #11 Panfrost Acceleration)

To enable hardware-accelerated rendering and provide verifiable diagnostic evidence for Issue #11 (GPU Panfrost bringup on Mali-G78), the offline depot includes the full Panfrost Gallium userspace stack:

1. **`mesa-dri-gallium` (26.3.1-r0)**:
   - Installs `/usr/lib/dri/panfrost_dri.so` (and associated Gallium pipe-loader drivers).
   - Mandatory requirement for Wayland compositors (`phoc`) running with `WLR_RENDERER=gles2`. Without this package, EGL/GLES2 fails to bind to `/dev/dri/renderD128` and falls back to software rasterization (`llvmpipe`) or fails compositor initialization.
2. **`mesa-utils` (9.0.0-r6)**:
   - Provides `eglinfo` and `es2_info` for driver string verification.
   - Used to extract the verbatim OpenGL ES vendor, renderer (`Mali-G78 (Panfrost)`), and supported extensions.
3. **`mesa-demos` (9.0.0-r6)**:
   - Provides `es2gears_wayland`, `eglgears_wayland`, and `eglkms` to test hardware render pipelines under Wayland without relying on full desktop application stacks.
4. **Transitive Dependency Closure**:
   - `glu` (9.0.3-r4), `freeglut` (3.8.0-r0), `libdecor` (0.2.5-r0), and `dbus-libs` (1.16.4-r1) are fully packaged and validated in the local repository.

---

## 4. Metadata Files in Depot

Beside the 263 `.apk` binaries, the depot directory `/home/gregor/phone-second-life-data/mb010/apk-depot/aarch64/` contains:
1. `APKINDEX.tar.gz`: Local ADBd v3 repository index generated via `apk mkndx` for native `apk --repository` consumption.
2. `APKINDEX.classic.tar.gz`: Standard gzip-compressed repository index compatible with legacy apk tools.
3. Upstream Index Backups:
   - `APKINDEX.alpine-main.tar.gz` (Alpine Linux edge/main)
   - `APKINDEX.alpine-community.tar.gz` (Alpine Linux edge/community)
   - `APKINDEX.pmos-main.tar.gz` (postmarketOS edge/main)
   - `APKINDEX.pmos-systemd.tar.gz` (postmarketOS extra-repos/systemd/main)
4. `urls.txt`: Package-to-URL mapping for 100% provenance verification (263 package URLs).
5. `SHA256SUMS`: Verifiable sha256 checksum list (`sha256sum -c SHA256SUMS` passes with 0 errors across 270 files).

---

## 5. Offline Installation Recipe (Copy-Paste Execution)

Execute these commands from the host once the device is accessible over SSH at `172.16.42.1`:

### Step 5.1: Transfer Depot from Host to Device
```bash
# Transfer the entire aarch64 depot to /tmp/apk-depot on target device
scp -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/opencode/gs101/issue4/known_hosts \
    -r /home/gregor/phone-second-life-data/mb010/apk-depot/aarch64 \
    user@172.16.42.1:/tmp/apk-depot
```

### Step 5.2: Install Minimal Application Set
Execute on device via `sshc.sh` (or direct SSH):
```bash
/tmp/opencode/gs101/issue4/sshc.sh '
set -euo pipefail

echo "=== Installing Minimal Application Set from Offline Depot ==="
# --allow-untrusted is used because the local index is self-signed/generated
sudo apk add --allow-untrusted \
    --repository /tmp/apk-depot \
    foot lxterminal pcmanfm galculator gnome-calculator

echo "=== Application Installation Completed Successfully ==="
'
```

### Step 5.3: Install GPU Panfrost Userspace & Benchmark Stack (Issue #11)
```bash
/tmp/opencode/gs101/issue4/sshc.sh '
set -euo pipefail

echo "=== Installing GPU Userspace & Panfrost Diagnostic Tools ==="
sudo apk add --allow-untrusted \
    --repository /tmp/apk-depot \
    mesa-dri-gallium mesa-utils mesa-demos

echo "=== Verifying Hardware Renderer via eglinfo ==="
eglinfo -B | grep -E "(OpenGL vendor|OpenGL renderer|OpenGL version)" || true
'
```

### Step 5.4: Verification of Installed Binaries
Verify that all applications and GPU tools are registered in the apk database and executable in `$PATH`:
```bash
/tmp/opencode/gs101/issue4/sshc.sh '
set -euo pipefail

echo "=== Checking Package Registration ==="
apk info -e foot lxterminal pcmanfm galculator gnome-calculator mesa-dri-gallium mesa-utils mesa-demos

echo "=== Checking Binary Executables ==="
which foot lxterminal pcmanfm galculator gnome-calculator eglinfo es2gears_wayland

echo "=== Checking Panfrost Driver Library ==="
ls -l /usr/lib/dri/panfrost_dri.so

echo "=== Checking Application Desktop Files ==="
ls -l /usr/share/applications/{foot,lxterminal,pcmanfm,galculator,org.gnome.Calculator}.desktop 2>/dev/null || true
'
```

### Step 5.5: Post-Install Clean-Up on Target (Optional)
Once verified, remove the temporary depot to reclaim disk space:
```bash
/tmp/opencode/gs101/issue4/sshc.sh 'rm -rf /tmp/apk-depot'
```
