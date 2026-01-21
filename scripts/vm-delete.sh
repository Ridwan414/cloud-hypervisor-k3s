#!/bin/bash
# Deletes a VM with the specified ID
# Usage: vm-delete.sh <VM_ID>
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"
BRIDGE_DEV="vmbridge"

if [[ -z "$1" ]]; then
    echo "Usage: $0 <VM_ID>"
    exit 1
fi

VM_ID="$1"
VM_DIR="${VM_BASE_DIR}/vm-${VM_ID}"
TAP_DEV="tap${VM_ID}"

if [[ $EUID -ne 0 ]]; then
    echo "Error: Run as root (sudo)"
    exit 1
fi

echo "Deleting VM ${VM_ID}..."

if [[ -d "${VM_DIR}" ]]; then
    # Stop VM if running
    PID_FILE="${VM_DIR}/vm.pid"
    if [[ -f "${PID_FILE}" ]]; then
        PID=$(cat "${PID_FILE}")
        kill -0 "${PID}" 2>/dev/null && kill -9 "${PID}" 2>/dev/null || true
        sleep 1
    fi

    # Kill orphaned processes
    ORPHAN_PID=$(pgrep -f "cloud-hypervisor.*vm-${VM_ID}/disk.raw" || true)
    [[ -n "${ORPHAN_PID}" ]] && kill -9 "${ORPHAN_PID}" 2>/dev/null || true

    # Clean up WireGuard port forwarding
    if [[ -f "${VM_DIR}/vm.conf" ]]; then
        source "${VM_DIR}/vm.conf"
        if [[ -n "${WG_PORT}" ]] && [[ -n "${VM_IP}" ]]; then
            PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
            iptables -D FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || true
            iptables -t nat -D PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}" 2>/dev/null || true
        fi
    fi

    rm -rf "${VM_DIR}"
fi

# Remove TAP device
if ip link show "${TAP_DEV}" &>/dev/null; then
    ip link set "${TAP_DEV}" down 2>/dev/null || true
    ip link set "${TAP_DEV}" nomaster 2>/dev/null || true
    ip tuntap del dev "${TAP_DEV}" mode tap 2>/dev/null || true
fi

# Remove bridge if no VMs remain
REMAINING_VMS=$(find "${VM_BASE_DIR}" -maxdepth 1 -type d -name "vm-*" 2>/dev/null | wc -l)
if [[ "${REMAINING_VMS}" -eq 0 ]] && ip link show "${BRIDGE_DEV}" &>/dev/null; then
    PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
    ip link set "${BRIDGE_DEV}" down 2>/dev/null || true
    ip link del "${BRIDGE_DEV}" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "${BRIDGE_DEV}" -o "${PRIMARY_IF}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${PRIMARY_IF}" -o "${BRIDGE_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi

echo "VM ${VM_ID} deleted."
