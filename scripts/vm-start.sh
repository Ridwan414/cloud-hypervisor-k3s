#!/bin/bash
# Starts a VM with the specified ID
# Usage: vm-start.sh <VM_ID>
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"

if [[ -z "$1" ]]; then
    echo "Usage: $0 <VM_ID>"
    exit 1
fi

VM_ID="$1"
VM_DIR="${VM_BASE_DIR}/vm-${VM_ID}"

if [[ ! -d "${VM_DIR}" ]]; then
    echo "Error: VM ${VM_ID} does not exist. Create it first."
    exit 1
fi

if [[ ! -f "${VM_DIR}/vm.conf" ]]; then
    echo "Error: VM config not found at ${VM_DIR}/vm.conf"
    exit 1
fi

source "${VM_DIR}/vm.conf"

CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-2048M}"

# Check required files
[[ -f "${VM_DIR}/disk.raw" ]] || { echo "Error: Disk image not found"; exit 1; }
[[ -f "${VM_DIR}/cloudinit.img" ]] || { echo "Error: Cloud-init image not found"; exit 1; }
[[ -f "${VM_BASE_DIR}/cloud-hypervisor" ]] || { echo "Error: cloud-hypervisor not found. Run 'make setup'"; exit 1; }
[[ -f "${VM_BASE_DIR}/hypervisor-fw" ]] || { echo "Error: hypervisor-fw not found"; exit 1; }
ip link show "${TAP_DEV}" &>/dev/null || { echo "Error: TAP device ${TAP_DEV} not found"; exit 1; }

# Check if already running
PID_FILE="${VM_DIR}/vm.pid"
if [[ -f "${PID_FILE}" ]]; then
    OLD_PID=$(cat "${PID_FILE}")
    if kill -0 "${OLD_PID}" 2>/dev/null; then
        echo "Error: VM ${VM_ID} already running (PID: ${OLD_PID})"
        exit 1
    fi
    rm -f "${PID_FILE}"
fi

# Set network capabilities if needed
if ! getcap "${VM_BASE_DIR}/cloud-hypervisor" | grep -q cap_net_admin; then
    sudo setcap cap_net_admin+ep "${VM_BASE_DIR}/cloud-hypervisor"
fi

cd "${VM_BASE_DIR}"

echo "Starting VM ${VM_ID}: IP=${VM_IP}, CPUs=${CPUS}, Memory=${MEMORY}"
echo "SSH: ssh ${VM_USER}@${VM_IP}"

./cloud-hypervisor \
    --firmware ./hypervisor-fw \
    --disk "path=${VM_DIR}/disk.raw" "path=${VM_DIR}/cloudinit.img" \
    --cpus boot="${CPUS}" \
    --memory size="${MEMORY}" \
    --net "tap=${TAP_DEV},mac=${MAC_ADDR},ip=,mask=" &

CH_PID=$!
echo "${CH_PID}" > "${PID_FILE}"

trap "rm -f '${PID_FILE}'" EXIT
wait "${CH_PID}" || true

echo "VM ${VM_ID} stopped."
