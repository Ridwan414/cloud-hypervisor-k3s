#!/bin/bash
# Stops a VM with the specified ID
# Usage: vm-stop.sh <VM_ID>
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"

# Validate arguments
if [[ -z "$1" ]]; then
    echo "Usage: $0 <VM_ID>"
    echo "Example: $0 1"
    exit 1
fi

VM_ID="$1"
VM_DIR="${VM_BASE_DIR}/vm-${VM_ID}"

# Check if VM exists
if [[ ! -d "${VM_DIR}" ]]; then
    echo "Error: VM ${VM_ID} does not exist"
    exit 1
fi

echo "=== Stopping VM ${VM_ID} ==="

PID_FILE="${VM_DIR}/vm.pid"

if [[ -f "${PID_FILE}" ]]; then
    PID=$(cat "${PID_FILE}")

    if kill -0 "${PID}" 2>/dev/null; then
        echo "Stopping cloud-hypervisor process (PID: ${PID})..."

        # Try graceful shutdown first
        kill "${PID}" 2>/dev/null || true

        # Wait up to 5 seconds for graceful shutdown
        for i in {1..10}; do
            if ! kill -0 "${PID}" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done

        # Force kill if still running
        if kill -0 "${PID}" 2>/dev/null; then
            echo "Force killing process..."
            kill -9 "${PID}" 2>/dev/null || true
        fi

        rm -f "${PID_FILE}"
        echo "VM ${VM_ID} stopped."
    else
        echo "VM ${VM_ID} is not running (stale PID file)"
        rm -f "${PID_FILE}"
    fi
else
    echo "VM ${VM_ID} is not running (no PID file)"

    # Try to find and kill any orphaned process
    # Look for cloud-hypervisor using this VM's disk
    ORPHAN_PID=$(pgrep -f "cloud-hypervisor.*vm-${VM_ID}/disk.raw" || true)
    if [[ -n "${ORPHAN_PID}" ]]; then
        echo "Found orphaned process (PID: ${ORPHAN_PID}), stopping..."
        kill -9 "${ORPHAN_PID}" 2>/dev/null || true
        echo "Orphaned process killed."
    fi
fi
