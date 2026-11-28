#!/usr/bin/env bash
# install-apps.sh - Configure persistent network routing & DNS, and deploy minimal application set on Google Tensor GS101 (raven)
# NOTE: DO NOT EXECUTE WHILE DEVICE IS OFFLINE OR WITHOUT OPERATOR AUTHORIZATION.
set -euo pipefail

TARGET_HOST="${TARGET_HOST:-172.16.42.1}"
TARGET_USER="${TARGET_USER:-user}"
HOST_ROUTER_IP="${HOST_ROUTER_IP:-172.16.42.2}"
APK_DEPOT_LOCAL="${APK_DEPOT_LOCAL:-/home/gregor/phone-second-life-data/mb010/apk-depot/aarch64}"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-/home/gregor/phone-second-life-data/mb010/deploy-harden/ssh/known_hosts}"
if [ ! -f "${KNOWN_HOSTS_FILE}" ] && [ -f "/tmp/opencode/gs101/issue4/known_hosts" ]; then
    KNOWN_HOSTS_FILE="/tmp/opencode/gs101/issue4/known_hosts"
fi
SSH_OPTS="-i ~/.ssh/id_ed25519 -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3"
SCP_OPTS="-i ~/.ssh/id_ed25519 -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3"

echo "=== Google Tensor GS101 (raven) Application & Network Persistence Deployment ==="
echo "Target: ${TARGET_USER}@${TARGET_HOST}"
echo "Gateway: ${HOST_ROUTER_IP}"
echo "Depot: ${APK_DEPOT_LOCAL}"

# Precondition check: Device must be reachable over SSH, else exit 10
if ! ping -c 1 -W 2 "${TARGET_HOST}" >/dev/null 2>&1; then
    echo "ERROR: Target ${TARGET_HOST} is unreachable (ping failed). Exit 10." >&2
    exit 10
fi

if ! ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "true" 2>/dev/null; then
    echo "ERROR: Target ${TARGET_HOST} SSH connection failed. Exit 10." >&2
    exit 10
fi

echo "[1/3] Configuring persistent default route and DNS (app-availability.md §3.1) ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
    set -euo pipefail
    echo "--> Configuring default route via 172.16.42.2 on usb0 ..."
    sudo mkdir -p /etc/systemd/system/unudhcpd@usb0.service.d/
    cat << "ROUTE_EOF" | sudo tee /etc/systemd/system/unudhcpd@usb0.service.d/route.conf >/dev/null
[Service]
ExecStartPost=/sbin/ip route replace default via 172.16.42.2 dev usb0
ROUTE_EOF

    echo "--> Configuring persistent DNS (1.1.1.1) in systemd-resolved ..."
    sudo mkdir -p /etc/systemd/resolved.conf.d/
    cat << "DNS_EOF" | sudo tee /etc/systemd/resolved.conf.d/dns.conf >/dev/null
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8
Domains=~.
DNS_EOF

    echo "--> Applying systemd reload and restarting services ..."
    sudo systemctl daemon-reload
    sudo systemctl restart unudhcpd@usb0.service || true
    sudo systemctl restart systemd-resolved.service

    # Ensure runtime default route immediately
    sudo ip route replace default via 172.16.42.2 dev usb0 2>/dev/null || true
'

echo "--- Verifying Network & DNS Connectivity ---"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
    echo "Default route:"; ip route show default
    echo "Resolved status:"; resolvectl status 2>/dev/null | grep -E "DNS Servers|Protocols" || true
    echo "Ping to 1.1.1.1:"; ping -c 2 -W 2 1.1.1.1 || echo "WARNING: Ping 1.1.1.1 failed (host NAT may not be configured)."
'

echo "[2/3] Installing minimal application set (foot, lxterminal, pcmanfm, galculator, gnome-calculator) ..."
ONLINE_OK=false
if ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "sudo apk update && sudo apk add foot lxterminal pcmanfm galculator gnome-calculator"; then
    echo "SUCCESS: Applications installed online via apk mirror."
    ONLINE_OK=true
else
    echo "NOTICE: Online apk install failed or repository unreachable. Attempting offline fallback from host apk-depot ..."
fi

# Offline fallback if online install failed
if [ "${ONLINE_OK}" != "true" ]; then
    if [ ! -d "${APK_DEPOT_LOCAL}" ]; then
        echo "ERROR: Local apk depot not found at ${APK_DEPOT_LOCAL}" >&2
        exit 1
    fi
    echo "--> Sideloading APK packages from host depot to target /tmp/apk-depot ..."
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" "mkdir -p /tmp/apk-depot"
    scp $SCP_OPTS -r "${APK_DEPOT_LOCAL}"/* "${TARGET_USER}@${TARGET_HOST}:/tmp/apk-depot/"
    echo "--> Installing packages from local depot repository ..."
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
        sudo apk add --allow-untrusted --repository /tmp/apk-depot foot lxterminal pcmanfm galculator gnome-calculator
        rm -rf /tmp/apk-depot
    '
fi

echo "[3/3] Verifying installed applications and binaries (apk info -e, which) ..."
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_HOST}" '
    set -euo pipefail
    echo "--- Package Registration (apk info -e) ---"
    apk info -e foot lxterminal pcmanfm galculator gnome-calculator

    echo "--- Binary Paths (which) ---"
    for bin in foot lxterminal pcmanfm galculator gnome-calculator; do
        which "$bin" || echo "MISSING BINARY: $bin"
    done
'

echo "=== install-apps.sh completed successfully. ==="
