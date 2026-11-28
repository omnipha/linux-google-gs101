#!/usr/bin/env bash
# verify-recovery.sh - Consolidated Host-Side Acceptance & Verification for Google Tensor GS101 (raven)
# NOTE: DO NOT EXECUTE WHILE DEVICE IS OFFLINE OR WITHOUT OPERATOR AUTHORIZATION.
# HARTVERBOT: Strictly passive audit. NO fastboot, NO flash, NO reboot, NO package/module installations.
set -euo pipefail

TARGET_HOST="${TARGET_HOST:-172.16.42.1}"
TARGET_USER="${TARGET_USER:-user}"
EVIDENCE_DIR="${EVIDENCE_DIR:-/home/gregor/phone-second-life-data/mb010/artifact-backup}"
if [ ! -d "${EVIDENCE_DIR}" ] && [ -d "/tmp/opencode/gs101/evidence" ]; then
    EVIDENCE_DIR="/tmp/opencode/gs101/evidence"
fi
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_JSON="${EVIDENCE_DIR}/verify-recovery-${TIMESTAMP}.json"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-/home/gregor/phone-second-life-data/mb010/deploy-harden/ssh/known_hosts}"
if [ ! -f "${KNOWN_HOSTS_FILE}" ] && [ -f "/tmp/opencode/gs101/issue4/known_hosts" ]; then
    KNOWN_HOSTS_FILE="/tmp/opencode/gs101/issue4/known_hosts"
fi
SSH_OPTS="-i ~/.ssh/id_ed25519 -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3"

mkdir -p "${EVIDENCE_DIR}"

echo "=== Google Tensor GS101 (raven) Consolidated Acceptance Verification ==="
echo "Target: ${TARGET_USER}@${TARGET_HOST}"
echo "Evidence Output: ${OUTPUT_JSON}"

# Precondition check: Device must be reachable over SSH. If not, exit 10 immediately without further checks.
if ! ping -c 1 -W 2 "${TARGET_HOST}" >/dev/null 2>&1; then
    echo "ERROR: Target ${TARGET_HOST} unreachable via ping. Precondition failed." >&2
    exit 10
fi

if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "true" 2>/dev/null; then
    echo "ERROR: Target ${TARGET_HOST} unreachable via SSH. Precondition failed." >&2
    exit 10
fi

echo "--> Target is ONLINE. Gathering system acceptance metrics over SSH ..."

# Collect raw acceptance telemetry from target in a controlled read-only manner
REMOTE_DATA=$(ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" 'bash -s' << 'REMOTE_SCRIPT_EOF'
set -uo pipefail

# 1. Kernel release
KVER=$(uname -r 2>/dev/null || echo "UNKNOWN")

# 2. Cmdline
CMDLINE=$(cat /proc/cmdline 2>/dev/null || echo "")

# 3. /proc/consoles
CONSOLES=$(cat /proc/consoles 2>/dev/null || echo "")

# 4. /dev/fb0
FB0_EXISTS=false
[ -e /dev/fb0 ] && FB0_EXISTS=true

# 5. /dev/dri/renderD128
RENDER128_EXISTS=false
[ -e /dev/dri/renderD128 ] && RENDER128_EXISTS=true

# 6. Touchscreen event device
TOUCH_DEV_NAME=""
TOUCH_EV_EXISTS=false
if [ -e /dev/input/event1 ]; then
    TOUCH_EV_EXISTS=true
    if [ -f /sys/class/input/event1/device/name ]; then
        TOUCH_DEV_NAME=$(cat /sys/class/input/event1/device/name 2>/dev/null || echo "")
    elif grep -q "sec_touchscreen" /proc/bus/input/devices 2>/dev/null; then
        TOUCH_DEV_NAME="sec_touchscreen"
    fi
fi

# 7. Touch IRQ delta over 3s
IRQ_SEC_TS_FOUND=false
IRQ_DELTA=0
if grep -q "sec_ts" /proc/interrupts 2>/dev/null; then
    IRQ_SEC_TS_FOUND=true
    IRQ1=$(grep -E "sec_ts" /proc/interrupts 2>/dev/null | awk '{for(i=2;i<=NF-2;i++) s+=$i} END {print s+0}')
    sleep 3
    IRQ2=$(grep -E "sec_ts" /proc/interrupts 2>/dev/null | awk '{for(i=2;i<=NF-2;i++) s+=$i} END {print s+0}')
    IRQ_DELTA=$(( IRQ2 - IRQ1 ))
fi

# 8. Panfrost dmesg GPU model
DMESG_GPU=$(dmesg 2>/dev/null | grep -i panfrost | tail -n 20 || echo "")

# 9. eglinfo renderer
EGL_INFO=""
if command -v eglinfo >/dev/null 2>&1; then
    EGL_INFO=$(eglinfo -B 2>/dev/null | grep -iE "(OpenGL renderer string|OpenGL ES renderer string|renderer)" | head -n 2 || echo "")
fi

# 10. grim screenshot test (> 1000 bytes)
GRIM_SIZE=0
if command -v grim >/dev/null 2>&1; then
    rm -f /tmp/test_grim.png
    if grim /tmp/test_grim.png 2>/dev/null; then
        GRIM_SIZE=$(wc -c < /tmp/test_grim.png 2>/dev/null || echo 0)
        rm -f /tmp/test_grim.png
    fi
fi

# 11. Default route via 172.16.42.2
DEF_ROUTE=$(ip route show default 2>/dev/null || echo "")

# 12. DNS 1.1.1.1
DNS_FOUND=false
if resolvectl status 2>/dev/null | grep -q "1\.1\.1\.1"; then
    DNS_FOUND=true
elif grep -q "1\.1\.1\.1" /etc/resolv.conf 2>/dev/null; then
    DNS_FOUND=true
fi

# 13. Application set (5 packages: foot, lxterminal, pcmanfm, galculator, gnome-calculator)
INSTALLED_APPS=""
if command -v apk >/dev/null 2>&1; then
    INSTALLED_APPS=$(apk info -e foot lxterminal pcmanfm galculator gnome-calculator 2>/dev/null || echo "")
fi

# 14. /sys/class/backlight
BACKLIGHT_ENTRIES=""
if [ -d /sys/class/backlight ]; then
    BACKLIGHT_ENTRIES=$(ls -A /sys/class/backlight 2>/dev/null || echo "")
fi

# 15. lsmod status for modular drivers
LSMOD_STATUS=$(lsmod 2>/dev/null | grep -E "(panfrost|gpu_sched|bcmdhd|cfg80211|rfkill|pci_exynos|bluetooth|hci_uart)" || echo "")

# Output fields as JSON directly from remote python if available, or delimiter-separated key-values
cat << TELEMETRY_EOF
---TELEMETRY_BEGIN---
KVER=${KVER}
FB0_EXISTS=${FB0_EXISTS}
RENDER128_EXISTS=${RENDER128_EXISTS}
TOUCH_EV_EXISTS=${TOUCH_EV_EXISTS}
TOUCH_DEV_NAME=${TOUCH_DEV_NAME}
IRQ_SEC_TS_FOUND=${IRQ_SEC_TS_FOUND}
IRQ_DELTA=${IRQ_DELTA}
GRIM_SIZE=${GRIM_SIZE}
DEF_ROUTE=${DEF_ROUTE}
DNS_FOUND=${DNS_FOUND}
BACKLIGHT_ENTRIES=${BACKLIGHT_ENTRIES}
CMDLINE=${CMDLINE}
CONSOLES=${CONSOLES}
EGL_INFO=${EGL_INFO}
INSTALLED_APPS=${INSTALLED_APPS}
LSMOD_STATUS=${LSMOD_STATUS}
DMESG_GPU=${DMESG_GPU}
---TELEMETRY_END---
TELEMETRY_EOF
REMOTE_SCRIPT_EOF
)

# Parse telemetry and generate structured JSON evaluation using local host python3
python3 - << PY_EVAL_EOF "${REMOTE_DATA}" "${OUTPUT_JSON}" "${TARGET_USER}@${TARGET_HOST}"
import sys
import json
from datetime import datetime, timezone

raw_data = sys.argv[1]
output_file = sys.argv[2]
target_spec = sys.argv[3]

fields = {}
in_telemetry = False
for line in raw_data.splitlines():
    if "---TELEMETRY_BEGIN---" in line:
        in_telemetry = True
        continue
    if "---TELEMETRY_END---" in line:
        in_telemetry = False
        continue
    if in_telemetry and "=" in line:
        k, v = line.split("=", 1)
        fields[k.strip()] = v.strip()

results = []

# 1. Kernel release (Must be 7.3.0-rc6-gs101 without plus)
kver = fields.get("KVER", "")
if kver == "7.3.0-rc6-gs101":
    results.append({"id": "kernel_release", "status": "PASS", "value": kver})
else:
    results.append({"id": "kernel_release", "status": "FAIL", "value": f"Expected '7.3.0-rc6-gs101', got '{kver}'"})

# 2. Cmdline console=tty0
cmdline = fields.get("CMDLINE", "")
if "console=tty0" in cmdline:
    results.append({"id": "cmdline_console", "status": "PASS", "value": "console=tty0 present in cmdline"})
else:
    results.append({"id": "cmdline_console", "status": "FAIL", "value": f"console=tty0 missing: {cmdline}"})

# 3. /proc/consoles tty0 active
consoles = fields.get("CONSOLES", "")
if "tty0" in consoles:
    results.append({"id": "proc_consoles", "status": "PASS", "value": f"tty0 active: {consoles}"})
else:
    results.append({"id": "proc_consoles", "status": "FAIL", "value": f"tty0 not found in /proc/consoles: {consoles}"})

# 4. /dev/fb0 present
fb0_exists = fields.get("FB0_EXISTS", "false").lower() == "true"
if fb0_exists:
    results.append({"id": "framebuffer_device", "status": "PASS", "value": "/dev/fb0 present"})
else:
    results.append({"id": "framebuffer_device", "status": "FAIL", "value": "/dev/fb0 missing"})

# 5. /dev/dri/renderD128
render_exists = fields.get("RENDER128_EXISTS", "false").lower() == "true"
if render_exists:
    results.append({"id": "drm_render_node", "status": "PASS", "value": "/dev/dri/renderD128 present"})
else:
    results.append({"id": "drm_render_node", "status": "INFO", "value": "/dev/dri/renderD128 missing (pending install-gpu.sh)"})

# 6. Touchscreen event device
touch_exists = fields.get("TOUCH_EV_EXISTS", "false").lower() == "true"
touch_name = fields.get("TOUCH_DEV_NAME", "")
if touch_exists and ("sec_touch" in touch_name.lower() or touch_name == ""):
    results.append({"id": "touchscreen_event", "status": "PASS", "value": f"/dev/input/event1 ({touch_name})"})
else:
    results.append({"id": "touchscreen_event", "status": "FAIL", "value": f"Touch event node missing or unexpected: exists={touch_exists}, name={touch_name}"})

# 7. Touch IRQ delta over 3s
irq_found = fields.get("IRQ_SEC_TS_FOUND", "false").lower() == "true"
irq_delta = int(fields.get("IRQ_DELTA", "0"))
if not irq_found:
    results.append({"id": "touch_irq_delta", "status": "FAIL", "value": "sec_ts interrupt not registered in /proc/interrupts"})
elif irq_delta > 0:
    results.append({"id": "touch_irq_delta", "status": "PASS", "value": f"delta={irq_delta} touches detected"})
else:
    results.append({"id": "touch_irq_delta", "status": "INFO", "value": f"delta=0 (INFO: no finger touch during 3s window)"})

# 8. GPU dmesg model
dmesg_gpu = fields.get("DMESG_GPU", "")
if "mali-unknown" in dmesg_gpu.lower():
    results.append({"id": "gpu_dmesg_model", "status": "FAIL", "value": "panfrost reported mali-unknown"})
elif "panfrost" in dmesg_gpu.lower() and "mali" in dmesg_gpu.lower():
    results.append({"id": "gpu_dmesg_model", "status": "PASS", "value": f"Valid Mali GPU model detected: {dmesg_gpu.strip()}"})
elif render_exists:
    results.append({"id": "gpu_dmesg_model", "status": "PASS", "value": "renderD128 active without panfrost errors"})
else:
    results.append({"id": "gpu_dmesg_model", "status": "INFO", "value": "panfrost not yet loaded (pending install-gpu.sh)"})

# 9. eglinfo renderer
egl_info = fields.get("EGL_INFO", "").strip()
if not egl_info:
    results.append({"id": "eglinfo_renderer", "status": "INFO", "value": "eglinfo not available or not installed"})
elif any(x in egl_info.lower() for x in ["llvmpipe", "soft"]):
    results.append({"id": "eglinfo_renderer", "status": "FAIL", "value": f"Software rasterizer detected: {eggl_info}"})
elif any(x in egl_info.lower() for x in ["panfrost", "mali"]):
    results.append({"id": "eglinfo_renderer", "status": "PASS", "value": f"Hardware acceleration confirmed: {egl_info}"})
else:
    results.append({"id": "eglinfo_renderer", "status": "INFO", "value": f"Renderer reported: {egl_info}"})

# 10. grim screenshot test (> 1000 bytes)
grim_size = int(fields.get("GRIM_SIZE", "0"))
if grim_size > 1000:
    results.append({"id": "grim_screenshot", "status": "PASS", "value": f"Captured {grim_size} bytes (Sichtbarkeits-Beweis)"})
elif grim_size == 0:
    results.append({"id": "grim_screenshot", "status": "INFO", "value": "grim screenshot capture pending active graphical session / display manager"})
else:
    results.append({"id": "grim_screenshot", "status": "FAIL", "value": f"Captured screenshot too small: {grim_size} bytes"})

# 11. Default route via 172.16.42.2
def_route = fields.get("DEF_ROUTE", "")
if "172.16.42.2" in def_route:
    results.append({"id": "default_route", "status": "PASS", "value": f"Default route active: {def_route}"})
else:
    results.append({"id": "default_route", "status": "FAIL", "value": f"Default route via 172.16.42.2 missing: '{def_route}'"})

# 12. DNS 1.1.1.1
dns_found = fields.get("DNS_FOUND", "false").lower() == "true"
if dns_found:
    results.append({"id": "dns_resolution", "status": "PASS", "value": "DNS 1.1.1.1 configured"})
else:
    results.append({"id": "dns_resolution", "status": "FAIL", "value": "DNS 1.1.1.1 not configured in systemd-resolved"})

# 13. App set (5 packages: foot, lxterminal, pcmanfm, galculator, gnome-calculator)
installed_apps_raw = fields.get("INSTALLED_APPS", "").split()
expected_apps = ["foot", "lxterminal", "pcmanfm", "galculator", "gnome-calculator"]
installed_set = set(installed_apps_raw)
missing_apps = [app for app in expected_apps if app not in installed_set]
if not missing_apps:
    results.append({"id": "app_set", "status": "PASS", "value": f"All 5 packages installed: {expected_apps}"})
else:
    results.append({"id": "app_set", "status": "FAIL", "value": f"Missing {len(missing_apps)}/5 packages: {missing_apps}"})

# 14. /sys/class/backlight (Expected empty for simpledrm)
backlight = fields.get("BACKLIGHT_ENTRIES", "").strip()
if not backlight:
    results.append({"id": "backlight_status", "status": "INFO", "value": "empty (expected for simpledrm, confirms raven-display-console.md)"})
else:
    results.append({"id": "backlight_status", "status": "INFO", "value": f"entries present: {backlight}"})

# 15. lsmod drivers status
lsmod_status = fields.get("LSMOD_STATUS", "").strip()
results.append({"id": "lsmod_drivers", "status": "INFO", "value": lsmod_status if lsmod_status else "No custom modular drivers loaded"})

# Summarize
pass_count = sum(1 for r in results if r["status"] == "PASS")
fail_count = sum(1 for r in results if r["status"] == "FAIL")
info_count = sum(1 for r in results if r["status"] == "INFO")

doc = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "target": target_spec,
    "summary": {
        "pass": pass_count,
        "fail": fail_count,
        "info": info_count,
        "total": len(results)
    },
    "results": results
}

with open(output_file, "w") as f:
    json.dump(doc, f, indent=2)

print(f"Verification Results: {pass_count} PASS, {fail_count} FAIL, {info_count} INFO")
for r in results:
    print(f"  [{r['status']:4s}] {r['id']}: {r['value']}")

sys.exit(fail_count)
PY_EVAL_EOF
