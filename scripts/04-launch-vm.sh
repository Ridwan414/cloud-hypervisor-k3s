#!/bin/bash
# Launches the cloud-hypervisor VM
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="${SCRIPT_DIR}/../vm"

# Configuration
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-2048M}"
TAP_DEV="${TAP_DEV:-tap0}"
MAC_ADDR="${MAC_ADDR:-12:34:56:78:9a:bc}"
BOOT_MODE="${BOOT_MODE:-firmware}"  # firmware or kernel

echo "=== Launching Cloud Hypervisor VM ==="
echo "CPUs: ${CPUS}"
echo "Memory: ${MEMORY}"
echo "Boot mode: ${BOOT_MODE}"
echo "TAP device: ${TAP_DEV}"

cd "${VM_DIR}"

# Detect architecture and set image name
ARCH=$(uname -m)
if [[ "${ARCH}" == "x86_64" ]]; then
    IMAGE_NAME="jammy-server-cloudimg-amd64.raw"
    KERNEL_PATH="linux-cloud-hypervisor/arch/x86/boot/compressed/vmlinux.bin"
elif [[ "${ARCH}" == "aarch64" ]]; then
    IMAGE_NAME="jammy-server-cloudimg-arm64.raw"
    KERNEL_PATH="linux-cloud-hypervisor/arch/arm64/boot/Image"
else
    echo "Unsupported architecture: ${ARCH}"
    exit 1
fi

# Check required files
for file in cloud-hypervisor "${IMAGE_NAME}" cloudinit.img; do
    if [[ ! -f "${file}" ]]; then
        echo "ERROR: Required file not found: ${file}"
        echo "Run the setup scripts first:"
        echo "  ./scripts/01-setup.sh"
        echo "  ./scripts/02-create-cloudinit.sh"
        exit 1
    fi
done

# Check TAP device
if ! ip link show "${TAP_DEV}" &>/dev/null; then
    echo "ERROR: TAP device ${TAP_DEV} not found"
    echo "Run: sudo ./scripts/03-setup-network.sh"
    exit 1
fi

# Set capabilities if needed
if ! getcap ./cloud-hypervisor | grep -q cap_net_admin; then
    echo "Setting network capabilities on cloud-hypervisor..."
    sudo setcap cap_net_admin+ep ./cloud-hypervisor
fi

echo ""
echo "Starting VM..."
echo "Console will appear below. Press Ctrl+C to stop the VM."
echo "SSH will be available at: ssh cloud@192.168.100.2 (password: cloud123)"
echo ""
echo "=========================================="

if [[ "${BOOT_MODE}" == "kernel" ]]; then
    if [[ ! -f "${KERNEL_PATH}" ]]; then
        echo "ERROR: Kernel not found at ${KERNEL_PATH}"
        echo "Either build the kernel or use BOOT_MODE=firmware"
        exit 1
    fi

    ./cloud-hypervisor \
        --kernel "${KERNEL_PATH}" \
        --disk path="${IMAGE_NAME}" path=cloudinit.img \
        --cmdline "console=hvc0 root=/dev/vda1 rw" \
        --cpus boot="${CPUS}" \
        --memory size="${MEMORY}" \
        --net "tap=${TAP_DEV},mac=${MAC_ADDR},ip=,mask="
else
    if [[ ! -f "hypervisor-fw" ]]; then
        echo "ERROR: Firmware not found: hypervisor-fw"
        exit 1
    fi

    ./cloud-hypervisor \
        --firmware ./hypervisor-fw \
        --disk path="${IMAGE_NAME}" path=cloudinit.img \
        --cpus boot="${CPUS}" \
        --memory size="${MEMORY}" \
        --net "tap=${TAP_DEV},mac=${MAC_ADDR},ip=,mask="
fi
