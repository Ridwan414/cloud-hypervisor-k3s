#!/bin/bash
# Starts a VM with the specified ID
# Usage: vm-start.sh <VM_ID>
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
    echo "Create it first with: make vm-create ID=${VM_ID}"
    exit 1
fi

# Load VM config
if [[ -f "${VM_DIR}/vm.conf" ]]; then
    source "${VM_DIR}/vm.conf"
else
    echo "Error: VM config not found at ${VM_DIR}/vm.conf"
    exit 1
fi

# Configuration
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-2048M}"
BOOT_MODE="${BOOT_MODE:-firmware}"

echo "=== Starting VM ${VM_ID} ==="
echo "CPUs: ${CPUS}"
echo "Memory: ${MEMORY}"
echo "Boot mode: ${BOOT_MODE}"
echo "TAP device: ${TAP_DEV}"
echo "IP address: ${VM_IP}"

# Check required files
if [[ ! -f "${VM_DIR}/disk.raw" ]]; then
    echo "Error: Disk image not found: ${VM_DIR}/disk.raw"
    exit 1
fi

if [[ ! -f "${VM_DIR}/cloudinit.img" ]]; then
    echo "Error: Cloud-init image not found: ${VM_DIR}/cloudinit.img"
    exit 1
fi

if [[ ! -f "${VM_BASE_DIR}/cloud-hypervisor" ]]; then
    echo "Error: cloud-hypervisor binary not found"
    echo "Run 'make setup' first"
    exit 1
fi

# Check TAP device
if ! ip link show "${TAP_DEV}" &>/dev/null; then
    echo "Error: TAP device ${TAP_DEV} not found"
    echo "Recreate the VM with: make vm-delete ID=${VM_ID} && make vm-create ID=${VM_ID}"
    exit 1
fi

# Check if VM is already running
PID_FILE="${VM_DIR}/vm.pid"
if [[ -f "${PID_FILE}" ]]; then
    OLD_PID=$(cat "${PID_FILE}")
    if kill -0 "${OLD_PID}" 2>/dev/null; then
        echo "Error: VM ${VM_ID} is already running (PID: ${OLD_PID})"
        echo "Stop it first with: make vm-stop ID=${VM_ID}"
        exit 1
    else
        rm -f "${PID_FILE}"
    fi
fi

# Set capabilities if needed
if ! getcap "${VM_BASE_DIR}/cloud-hypervisor" | grep -q cap_net_admin; then
    echo "Setting network capabilities on cloud-hypervisor..."
    sudo setcap cap_net_admin+ep "${VM_BASE_DIR}/cloud-hypervisor"
fi

cd "${VM_BASE_DIR}"

echo ""
echo "Starting VM..."
echo "Console will appear below. Press Ctrl+C to stop the VM."
echo "SSH: ssh ${VM_USER}@${VM_IP} (password: cloud123)"
echo ""
echo "=========================================="

# Write PID file (will be overwritten by actual PID)
echo "$$" > "${PID_FILE}"

if [[ "${BOOT_MODE}" == "kernel" ]]; then
    ARCH=$(uname -m)
    if [[ "${ARCH}" == "x86_64" ]]; then
        KERNEL_PATH="linux-cloud-hypervisor/arch/x86/boot/compressed/vmlinux.bin"
    else
        KERNEL_PATH="linux-cloud-hypervisor/arch/arm64/boot/Image"
    fi

    if [[ ! -f "${KERNEL_PATH}" ]]; then
        echo "Error: Kernel not found at ${KERNEL_PATH}"
        echo "Either build the kernel or use BOOT_MODE=firmware"
        exit 1
    fi

    ./cloud-hypervisor \
        --kernel "${KERNEL_PATH}" \
        --disk "path=${VM_DIR}/disk.raw" "path=${VM_DIR}/cloudinit.img" \
        --cmdline "console=hvc0 root=/dev/vda1 rw" \
        --cpus boot="${CPUS}" \
        --memory size="${MEMORY}" \
        --net "tap=${TAP_DEV},mac=${MAC_ADDR},ip=,mask=" &
else
    if [[ ! -f "hypervisor-fw" ]]; then
        echo "Error: Firmware not found: hypervisor-fw"
        exit 1
    fi

    ./cloud-hypervisor \
        --firmware ./hypervisor-fw \
        --disk "path=${VM_DIR}/disk.raw" "path=${VM_DIR}/cloudinit.img" \
        --cpus boot="${CPUS}" \
        --memory size="${MEMORY}" \
        --net "tap=${TAP_DEV},mac=${MAC_ADDR},ip=,mask=" &
fi

# Save actual PID
CH_PID=$!
echo "${CH_PID}" > "${PID_FILE}"

# Wait for the process
wait "${CH_PID}" || true

# Clean up PID file on exit
rm -f "${PID_FILE}"
echo ""
echo "VM ${VM_ID} stopped."
