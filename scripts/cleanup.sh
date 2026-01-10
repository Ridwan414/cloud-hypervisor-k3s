#!/bin/bash
# Cleanup script: stops all VMs, removes all TAP devices, bridge, and iptables rules
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"
BRIDGE_DEV="vmbridge"

echo "=== Cleanup Cloud Hypervisor Environment ==="

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

# Get primary interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)

# Stop all running cloud-hypervisor processes
echo "Stopping all cloud-hypervisor processes..."
pkill -9 cloud-hypervisor 2>/dev/null || true

# Find and remove all VM directories and their TAP devices
echo "Removing VM directories and TAP devices..."

VM_DIRS=$(find "${VM_BASE_DIR}" -maxdepth 1 -type d -name "vm-*" 2>/dev/null || true)
for vm_dir in ${VM_DIRS}; do
    VM_ID=$(basename "${vm_dir}" | sed 's/vm-//')
    TAP_DEV="tap${VM_ID}"

    echo "  Removing VM ${VM_ID}..."

    # Remove TAP device
    if ip link show "${TAP_DEV}" &>/dev/null; then
        ip link set "${TAP_DEV}" down 2>/dev/null || true
        ip link set "${TAP_DEV}" nomaster 2>/dev/null || true
        ip tuntap del dev "${TAP_DEV}" mode tap 2>/dev/null || true
    fi

    # Remove VM directory
    rm -rf "${vm_dir}"
done

# Also clean up legacy single-VM setup (tap0 without vm-0 directory)
if ip link show "tap0" &>/dev/null; then
    echo "  Removing legacy TAP device tap0..."
    ip link set "tap0" down 2>/dev/null || true
    ip link set "tap0" nomaster 2>/dev/null || true
    ip tuntap del dev "tap0" mode tap 2>/dev/null || true
fi

# Remove bridge device
if ip link show "${BRIDGE_DEV}" &>/dev/null; then
    echo "Removing bridge ${BRIDGE_DEV}..."
    ip link set "${BRIDGE_DEV}" down 2>/dev/null || true
    ip link del "${BRIDGE_DEV}" 2>/dev/null || true
fi

# Remove iptables rules
echo "Removing iptables rules..."
iptables -t nat -D POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "${BRIDGE_DEV}" -o "${PRIMARY_IF}" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "${PRIMARY_IF}" -o "${BRIDGE_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# Also clean up old TAP-specific rules
for i in {0..10}; do
    iptables -D FORWARD -i "tap${i}" -o "${PRIMARY_IF}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${PRIMARY_IF}" -o "tap${i}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
done

# Clean up legacy files (from old single-VM setup)
if [[ -f "${VM_BASE_DIR}/cloudinit.img" ]]; then
    echo "Removing legacy cloud-init files..."
    rm -f "${VM_BASE_DIR}/cloudinit.img"
    rm -f "${VM_BASE_DIR}/meta-data"
    rm -f "${VM_BASE_DIR}/user-data"
    rm -f "${VM_BASE_DIR}/network-config"
fi

# Remove any stale PID files
find "${VM_BASE_DIR}" -name "vm.pid" -delete 2>/dev/null || true

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "Note: Base images and binaries were preserved in ${VM_BASE_DIR}/"
echo "To remove everything: rm -rf ${VM_BASE_DIR}"
