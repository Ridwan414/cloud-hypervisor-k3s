#!/bin/bash
# Cleanup script: removes TAP device and iptables rules
set -e

TAP_DEV="${TAP_DEV:-tap0}"

echo "=== Cleanup Cloud Hypervisor Environment ==="

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

# Remove TAP device
if ip link show "${TAP_DEV}" &>/dev/null; then
    echo "Removing TAP device ${TAP_DEV}..."
    ip link set "${TAP_DEV}" down
    ip tuntap del dev "${TAP_DEV}" mode tap
    echo "TAP device removed."
else
    echo "TAP device ${TAP_DEV} not found."
fi

# Get primary interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)

# Remove iptables rules
echo "Removing iptables rules..."
iptables -t nat -D POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "${TAP_DEV}" -o "${PRIMARY_IF}" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "${PRIMARY_IF}" -o "${TAP_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

echo ""
echo "=== Cleanup Complete ==="
