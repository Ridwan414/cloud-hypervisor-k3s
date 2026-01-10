#!/bin/bash
# Lists all VMs and their status
# Usage: vm-list.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"

echo "=== VM List ==="
echo ""

# Check if any VMs exist
VM_DIRS=$(find "${VM_BASE_DIR}" -maxdepth 1 -type d -name "vm-*" 2>/dev/null | sort -V)

if [[ -z "${VM_DIRS}" ]]; then
    echo "No VMs found."
    echo ""
    echo "Create a VM with: make vm-create ID=1"
    exit 0
fi

printf "%-6s %-18s %-10s %-20s %-10s\n" "ID" "IP" "TAP" "MAC" "STATUS"
printf "%-6s %-18s %-10s %-20s %-10s\n" "------" "------------------" "----------" "--------------------" "----------"

for vm_dir in ${VM_DIRS}; do
    VM_ID=$(basename "${vm_dir}" | sed 's/vm-//')

    # Load VM config
    if [[ -f "${vm_dir}/vm.conf" ]]; then
        source "${vm_dir}/vm.conf"
    else
        VM_IP="N/A"
        TAP_DEV="tap${VM_ID}"
        MAC_ADDR="N/A"
    fi

    # Check if running
    STATUS="stopped"
    PID_FILE="${vm_dir}/vm.pid"
    if [[ -f "${PID_FILE}" ]]; then
        PID=$(cat "${PID_FILE}")
        if kill -0 "${PID}" 2>/dev/null; then
            STATUS="running"
        fi
    fi

    # Also check for orphaned processes
    if [[ "${STATUS}" == "stopped" ]]; then
        ORPHAN_PID=$(pgrep -f "cloud-hypervisor.*vm-${VM_ID}/disk.raw" 2>/dev/null || true)
        if [[ -n "${ORPHAN_PID}" ]]; then
            STATUS="running*"
        fi
    fi

    printf "%-6s %-18s %-10s %-20s %-10s\n" "${VM_ID}" "${VM_IP}" "${TAP_DEV}" "${MAC_ADDR}" "${STATUS}"
done

echo ""
echo "Commands:"
echo "  make vm-start ID=N   Start a VM"
echo "  make vm-stop ID=N    Stop a VM"
echo "  make vm-ssh ID=N     SSH into a VM"
echo "  make vm-delete ID=N  Delete a VM"
echo ""
echo "* = orphaned process (no PID file)"
