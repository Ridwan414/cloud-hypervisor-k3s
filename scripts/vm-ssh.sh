#!/bin/bash
# SSH into a VM with the specified ID
# Usage: vm-ssh.sh <VM_ID>

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

# Load VM config
if [[ -f "${VM_DIR}/vm.conf" ]]; then
    source "${VM_DIR}/vm.conf"
else
    echo "Error: VM config not found at ${VM_DIR}/vm.conf"
    exit 1
fi

echo "Connecting to VM ${VM_ID} at ${VM_IP}..."
echo "User: ${VM_USER}, Password: cloud123"
echo ""

# Wait for SSH to be ready
MAX_WAIT=60
WAITED=0
echo "Waiting for SSH to be ready..."

while ! nc -z "${VM_IP}" 22 2>/dev/null; do
    if [[ ${WAITED} -ge ${MAX_WAIT} ]]; then
        echo ""
        echo "Error: SSH not available after ${MAX_WAIT} seconds"
        echo "Make sure the VM is running: make vm-start ID=${VM_ID}"
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    printf "."
done

echo ""
echo "SSH is ready. Connecting..."
echo ""

# Connect with SSH
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${VM_USER}@${VM_IP}"
