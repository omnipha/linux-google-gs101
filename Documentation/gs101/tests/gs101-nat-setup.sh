#!/usr/bin/env bash
# gs101-nat-setup.sh - Idempotent Host-NAT and IP Forwarding Setup for Google Tensor GS101 (raven)
# Configures host masquerading and IP forwarding for the USB CDC-NCM device network (172.16.42.0/24).
set -euo pipefail

DEV_SUBNET="${DEV_SUBNET:-172.16.42.0/24}"
DEV_HOST_IP="${DEV_HOST_IP:-172.16.42.2}"
SYSCTL_FILE="/etc/sysctl.d/99-gs101-nat.conf"

# Auto-detect default outbound WAN interface if not specified
if [ -z "${WAN_IFACE:-}" ]; then
    WAN_IFACE=$(/sbin/ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n 1 || echo "wlo1")
fi

echo "=== Google Tensor GS101 Host-NAT Configuration ==="
echo "Target Subnet:   ${DEV_SUBNET}"
echo "Host Gateway IP: ${DEV_HOST_IP}"
echo "Outbound WAN:    ${WAN_IFACE}"

# 1. IP Forwarding Check & Configuration
echo "[1/3] Checking IPv4 forwarding (net.ipv4.ip_forward) ..."
CURRENT_FWD=$(/sbin/sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)

if [ "${CURRENT_FWD}" != "1" ]; then
    echo "--> Enabling net.ipv4.ip_forward runtime ..."
    sudo /sbin/sysctl -w net.ipv4.ip_forward=1
else
    echo "--> net.ipv4.ip_forward is already active (=1)."
fi

# Make IP forwarding persistent via /etc/sysctl.d/
if [ ! -f "${SYSCTL_FILE}" ] || ! grep -q "net.ipv4.ip_forward=1" "${SYSCTL_FILE}" 2>/dev/null; then
    echo "--> Persisting net.ipv4.ip_forward=1 in ${SYSCTL_FILE} ..."
    printf "# GS101 CDC-NCM host router forwarding\nnet.ipv4.ip_forward=1\n" | sudo tee "${SYSCTL_FILE}" >/dev/null
    sudo chmod 0644 "${SYSCTL_FILE}"
else
    echo "--> ${SYSCTL_FILE} already configured."
fi

# 2. Iptables NAT Masquerade Check & Configuration
echo "[2/3] Checking iptables NAT POSTROUTING rules ..."
if ! sudo iptables -t nat -C POSTROUTING -s "${DEV_SUBNET}" -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null; then
    echo "--> Adding iptables MASQUERADE rule for ${DEV_SUBNET} out ${WAN_IFACE} ..."
    sudo iptables -t nat -A POSTROUTING -s "${DEV_SUBNET}" -o "${WAN_IFACE}" -j MASQUERADE
else
    echo "--> iptables MASQUERADE rule already present."
fi

# 3. Iptables FORWARD Rules Check & Configuration
echo "[3/3] Checking iptables FORWARD rules ..."
if ! sudo iptables -C FORWARD -s "${DEV_SUBNET}" -o "${WAN_IFACE}" -j ACCEPT 2>/dev/null; then
    echo "--> Adding FORWARD rule (outbound traffic from ${DEV_SUBNET}) ..."
    sudo iptables -A FORWARD -s "${DEV_SUBNET}" -o "${WAN_IFACE}" -j ACCEPT
fi

if ! sudo iptables -C FORWARD -i "${WAN_IFACE}" -d "${DEV_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    echo "--> Adding FORWARD rule (inbound established traffic to ${DEV_SUBNET}) ..."
    sudo iptables -A FORWARD -i "${WAN_IFACE}" -d "${DEV_SUBNET}" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

echo "=== Host NAT Setup Complete ==="
echo "Active NAT rule:"
sudo iptables -t nat -L POSTROUTING -v -n --line-numbers | grep -E "MASQUERADE.*172\.16\.42\.0" || true

echo ""
echo "Note on persistence across host reboots:"
echo "To persist iptables rules across host reboots, use iptables-persistent or netfilter-persistent:"
echo "  Debian/Ubuntu: sudo netfilter-persistent save  OR  sudo apt-get install iptables-persistent"
echo "  Arch/Alpine:   sudo iptables-save | sudo tee /etc/iptables/iptables.rules"
