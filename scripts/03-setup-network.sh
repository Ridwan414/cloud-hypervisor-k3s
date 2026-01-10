#!/bin/bash
# Sets up TAP networking for the VM
set -e

TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-192.168.100.1}"
TAP_CIDR="${TAP_CIDR:-24}"

echo "=== Setting Up TAP Network ==="
echo "TAP device: ${TAP_DEV}"
echo "TAP IP: ${TAP_IP}/${TAP_CIDR}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

# Detect primary network interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Primary interface: ${PRIMARY_IF}"

# Create TAP device if it doesn't exist
if ip link show "${TAP_DEV}" &>/dev/null; then
    echo "TAP device ${TAP_DEV} already exists"
else
    echo "Creating TAP device ${TAP_DEV}..."
    ip tuntap add dev "${TAP_DEV}" mode tap
fi

# Configure TAP device
echo "Configuring TAP device..."
ip addr flush dev "${TAP_DEV}" 2>/dev/null || true
ip addr add "${TAP_IP}/${TAP_CIDR}" dev "${TAP_DEV}"
ip link set "${TAP_DEV}" up

# Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Setup NAT rules (check if already exists)
if ! iptables -t nat -C POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE 2>/dev/null; then
    echo "Adding NAT masquerade rule..."
    iptables -t nat -A POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE
fi

if ! iptables -C FORWARD -i "${TAP_DEV}" -o "${PRIMARY_IF}" -j ACCEPT 2>/dev/null; then
    echo "Adding forward rules..."
    iptables -A FORWARD -i "${TAP_DEV}" -o "${PRIMARY_IF}" -j ACCEPT
    iptables -A FORWARD -i "${PRIMARY_IF}" -o "${TAP_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

echo ""
echo "=== Network Setup Complete ==="
echo ""
echo "TAP device status:"
ip addr show "${TAP_DEV}"
echo ""
echo "IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"
