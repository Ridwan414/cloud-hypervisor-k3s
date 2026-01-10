#!/bin/bash
# Deletes a VM with the specified ID
# Usage: vm-delete.sh <VM_ID>
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"
BRIDGE_DEV="vmbridge"

# Validate arguments
if [[ -z "$1" ]]; then
    echo "Usage: $0 <VM_ID>"
    echo "Example: $0 1"
    exit 1
fi

VM_ID="$1"
VM_DIR="${VM_BASE_DIR}/vm-${VM_ID}"
TAP_DEV="tap${VM_ID}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

echo "=== Deleting VM ${VM_ID} ==="

# Check if VM exists
if [[ ! -d "${VM_DIR}" ]]; then
    echo "Warning: VM directory ${VM_DIR} does not exist"
else
    # Stop VM if running
    PID_FILE="${VM_DIR}/vm.pid"
    if [[ -f "${PID_FILE}" ]]; then
        PID=$(cat "${PID_FILE}")
        if kill -0 "${PID}" 2>/dev/null; then
            echo "Stopping running VM..."
            kill -9 "${PID}" 2>/dev/null || true
            sleep 1
        fi
    fi

    # Also check for orphaned processes
    ORPHAN_PID=$(pgrep -f "cloud-hypervisor.*vm-${VM_ID}/disk.raw" || true)
    if [[ -n "${ORPHAN_PID}" ]]; then
        echo "Stopping orphaned process..."
        kill -9 "${ORPHAN_PID}" 2>/dev/null || true
    fi

    # Remove VM directory
    echo "Removing VM directory..."
    rm -rf "${VM_DIR}"
fi

# Remove TAP device
if ip link show "${TAP_DEV}" &>/dev/null; then
    echo "Removing TAP device ${TAP_DEV}..."
    ip link set "${TAP_DEV}" down 2>/dev/null || true
    ip link set "${TAP_DEV}" nomaster 2>/dev/null || true
    ip tuntap del dev "${TAP_DEV}" mode tap 2>/dev/null || true
else
    echo "TAP device ${TAP_DEV} does not exist"
fi

# Check if any other VMs exist - if not, remove the bridge
REMAINING_VMS=$(find "${VM_BASE_DIR}" -maxdepth 1 -type d -name "vm-*" 2>/dev/null | wc -l)
if [[ "${REMAINING_VMS}" -eq 0 ]]; then
    echo "No remaining VMs, removing bridge ${BRIDGE_DEV}..."
    if ip link show "${BRIDGE_DEV}" &>/dev/null; then
        # Get primary interface for iptables cleanup
        PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)

        ip link set "${BRIDGE_DEV}" down 2>/dev/null || true
        ip link del "${BRIDGE_DEV}" 2>/dev/null || true

        # Remove iptables rules
        iptables -t nat -D POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "${BRIDGE_DEV}" -o "${PRIMARY_IF}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "${PRIMARY_IF}" -o "${BRIDGE_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi
fi

echo ""
echo "=== VM ${VM_ID} Deleted ==="
