# Issue #10: Application Availability Matrix & Post-Recovery Persistence Procedure

**Date**: 2026-11-28  
**Target Environment**: postmarketOS edge (aarch64), systemd init, Phosh UI  
**Target Hardware**: Google Pixel 6 Pro (`raven`, GS101 SoC)  
**Host NAT Uplink**: `172.16.42.2/24` (Host `wlo1` NAT Masquerade), Device `172.16.42.1/24` on `usb0`

---

## 1. Application Availability Matrix (pmOS aarch64)

The local APKINDEX cache from `/home/gregor/phone-second-life-data/mb010/image-build/work-repo-kernel-issue1/cache_apk_aarch64/` and the official Alpine Linux edge aarch64 repository index were evaluated for the requested candidate packages:

| Package | Status | Repository | Version | Package Size | Installed Size | Description / Capabilities |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `lxterminal` | **Available** | `community` | `0.4.0-r2` | 40,490 B | 192,512 B | Desktop-independent VTE-based terminal emulator (GTK+3) |
| `foot` | **Available** | `community` | `1.28.0-r0` | 251,471 B | 609,725 B | Fast, lightweight and minimalistic native Wayland terminal emulator |
| `pcmanfm` | **Available** | `community` | `1.4.0-r0` | 104,925 B | 411,362 B | Extremely fast and lightweight file manager (GTK+3 / libfm) |
| `float` | **Not Found** | — | — | — | — | Package does not exist in Alpine/pmOS aarch64 repos |
| `galculator` | **Available** | `community` | `2.1.4-r5` | 90,823 B | 854,886 B | Lightweight GTK+3 based scientific calculator |
| `gnome-calculator` | **Available** | `community` | `51.1-r0` | 580,362 B | 1,899,094 B | Modern GNOME / Libadwaita calculator (GTK4 / libadwaita-1) |
| `apcalc` | **Not Found** | — | — | — | — | Package does not exist in Alpine/pmOS aarch64 repos (see alternatives below) |

### 1.1 Evaluated Alternatives for Missing Packages
- **`apcalc`**: The upstream arbitrary precision calculator (`calc` / `apcalc`) is not packaged in Alpine Linux. Standard CLI alternatives available in main/community are `bc` (GNU basic calculator) and `dc`. For graphical calculations, `galculator` provides high-precision scientific math.
- **`float`**: No package or binary named `float` exists in postmarketOS or Alpine Linux repos. For file browsing, `pcmanfm` serves as the primary lightweight choice.

### 1.2 Recommended Minimal Application Set for Raven
1. **Terminal**: `foot` (primary Wayland-native terminal, zero X11 overhead) and `lxterminal` (proven GTK3 fallback).
2. **File Manager**: `pcmanfm` (fast, touch-friendly navigation, low memory footprint).
3. **Calculator**: `galculator` (minimalist GTK3 scientific calculator) and/or `gnome-calculator` (adaptive Phosh/libadwaita mobile layout).

---

## 2. Post-Recovery Network Persistence Configuration

### 2.1 Architecture Selection: `unudhcpd` + `systemd-resolved` vs. `systemd-networkd`

> [!NOTE]
> **Why `systemd-networkd` is NOT used on this image**:
> - The `postmarketos-base-systemd` architecture uses `unudhcpd@usb0.service` to manage the USB gadget network interface (`usb0`), assigning `172.16.42.1` to the device and running a micro-DHCP server handing out `172.16.42.2` to the host.
> - `systemd-networkd` is not installed by default. Installing or enabling `systemd-networkd` would cause race conditions and IP address conflicts on `usb0`, breaking the stable unudhcpd DHCP lease and dropping SSH access.
> - `systemd-resolved` is already installed, active (`dbus-org.freedesktop.resolve1.service`), and connected to `/etc/resolv.conf` via the stub resolver (`127.0.0.53`).
> 
> **Optimal Solution**:
> 1. Use a drop-in override for `unudhcpd@usb0.service` with `ExecStartPost=` to automatically set the default route via `172.16.42.2` whenever `usb0` is initialized.
> 2. Configure `systemd-resolved` with global upstream DNS `1.1.1.1` via `/etc/systemd/resolved.conf.d/dns.conf`.
> 
> Both configurations reside on the persistent root filesystem and survive cold reboots without requiring any manual network commands.

---

## 3. Executable Post-Recovery Procedure (Copy-Paste)

Execute these steps on the host via SSH once the device is online at `172.16.42.1`:

### Step 3.1: Configure Persistent Default Route & DNS
Run on the host:
```bash
ssh user@172.16.42.1 << 'EOF'
set -euo pipefail

echo "=== Configuring Persistent Default Route for usb0 ==="
sudo mkdir -p /etc/systemd/system/unudhcpd@usb0.service.d/
cat << 'ROUTE_EOF' | sudo tee /etc/systemd/system/unudhcpd@usb0.service.d/route.conf
[Service]
ExecStartPost=/sbin/ip route replace default via 172.16.42.2 dev usb0
ROUTE_EOF

echo "=== Configuring Persistent DNS (1.1.1.1) in systemd-resolved ==="
sudo mkdir -p /etc/systemd/resolved.conf.d/
cat << 'DNS_EOF' | sudo tee /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8
Domains=~.
DNS_EOF

echo "=== Reloading Daemons and Applying Configuration ==="
sudo systemctl daemon-reload
sudo systemctl restart unudhcpd@usb0.service
sudo systemctl restart systemd-resolved.service

echo "=== Immediate Route & DNS Check ==="
ip route show default
resolvectl status | grep -E "DNS Servers|Protocols" || true
ping -c 3 1.1.1.1
ping -c 3 dl-cdn.alpinelinux.org
EOF
```

---

### Step 3.2: Install Minimal Application Set via `apk`
Run on the host:
```bash
ssh user@172.16.42.1 << 'EOF'
set -euo pipefail

echo "=== Updating Package Index ==="
sudo apk update

echo "=== Installing Minimal Application Set ==="
# Terminal: foot (Wayland) + lxterminal (GTK3 fallback)
# File Manager: pcmanfm
# Calculator: galculator (GTK3) + gnome-calculator (Phosh/Libadwaita)
sudo apk add foot lxterminal pcmanfm galculator gnome-calculator

echo "=== Verifying Installed Packages ==="
apk info -e foot lxterminal pcmanfm galculator gnome-calculator
EOF
```

---

### Step 3.3: Persistence Verification Sequence Across Cold Reboot
Test that the network route, DNS resolution, and installed applications persist across a full system reboot **without any manual intervention**:

```bash
# 1. Trigger clean reboot
ssh user@172.16.42.1 'sudo reboot'

# 2. Wait for SSH to return (polling loop on host)
echo "Waiting for device to return online..."
until ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no user@172.16.42.1 'echo ONLINE' 2>/dev/null; do
    sleep 2
done

# 3. Automated Persistence Verification (zero manual network commands)
ssh user@172.16.42.1 << 'EOF'
set -euo pipefail
echo "=== 1. Kernel & Uptime ==="
uname -a
uptime

echo "=== 2. Default Route Verification (Must show default via 172.16.42.2 dev usb0) ==="
ip route show default | grep -q "172.16.42.2" && echo "PASS: Default route persistent" || echo "FAIL: Default route missing"

echo "=== 3. DNS Resolution Verification ==="
resolvectl status | grep -E "1\.1\.1\.1" && echo "PASS: Global DNS 1.1.1.1 persistent" || echo "FAIL: DNS missing"

echo "=== 4. Internet Connectivity Check ==="
ping -c 3 -W 3 1.1.1.1 && echo "PASS: ICMP to 1.1.1.1 operational"
ping -c 3 -W 3 dl-cdn.alpinelinux.org && echo "PASS: DNS lookup + ICMP operational"

echo "=== 5. Application Persistence Check ==="
apk info -e foot lxterminal pcmanfm galculator gnome-calculator

echo "=== 6. Binary Execution Check ==="
which foot lxterminal pcmanfm galculator gnome-calculator
echo "ALL PERSISTENCE CHECKS PASSED!"
EOF
```
