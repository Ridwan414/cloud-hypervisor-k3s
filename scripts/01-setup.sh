#!/bin/bash
# Setup script: Downloads cloud-hypervisor, firmware, and Ubuntu cloud image
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="${SCRIPT_DIR}/../vm"

echo "=== Cloud Hypervisor VM Setup ==="
echo "VM directory: ${VM_DIR}"

mkdir -p "${VM_DIR}"
cd "${VM_DIR}"

# Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: ${ARCH}"

# Download cloud-hypervisor
if [[ ! -f "cloud-hypervisor" ]]; then
    echo "Downloading cloud-hypervisor..."
    if [[ "${ARCH}" == "x86_64" ]]; then
        wget -q --show-progress https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static -O cloud-hypervisor
    elif [[ "${ARCH}" == "aarch64" ]]; then
        wget -q --show-progress https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static-aarch64 -O cloud-hypervisor
    else
        echo "Unsupported architecture: ${ARCH}"
        exit 1
    fi
    chmod +x cloud-hypervisor
    echo "cloud-hypervisor downloaded."
else
    echo "cloud-hypervisor already exists, skipping."
fi

# Download firmware
if [[ ! -f "hypervisor-fw" ]]; then
    echo "Downloading hypervisor firmware..."
    wget -q --show-progress https://github.com/cloud-hypervisor/rust-hypervisor-firmware/releases/download/0.4.2/hypervisor-fw
    echo "Firmware downloaded."
else
    echo "hypervisor-fw already exists, skipping."
fi

# Download Ubuntu cloud image
IMAGE_NAME="jammy-server-cloudimg-amd64"
if [[ "${ARCH}" == "aarch64" ]]; then
    IMAGE_NAME="jammy-server-cloudimg-arm64"
fi

if [[ ! -f "${IMAGE_NAME}.raw" ]]; then
    if [[ ! -f "${IMAGE_NAME}.img" ]]; then
        echo "Downloading Ubuntu 22.04 cloud image..."
        wget -q --show-progress "https://cloud-images.ubuntu.com/jammy/current/${IMAGE_NAME}.img"
    fi

    echo "Converting image to raw format..."
    qemu-img convert -p -f qcow2 -O raw "${IMAGE_NAME}.img" "${IMAGE_NAME}.raw"
    echo "Image converted."

    # Optionally remove the qcow2 to save space
    # rm -f "${IMAGE_NAME}.img"
else
    echo "${IMAGE_NAME}.raw already exists, skipping."
fi

echo ""
echo "=== Setup Complete ==="
echo "Files in ${VM_DIR}:"
ls -lh "${VM_DIR}"
