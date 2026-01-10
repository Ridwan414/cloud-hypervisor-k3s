#!/bin/bash
# Main script to setup and launch the VM
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "  Cloud Hypervisor VM Setup and Launch"
echo "============================================"
echo ""

# Step 1: Download required files
echo "[1/4] Running setup..."
"${SCRIPT_DIR}/01-setup.sh"
echo ""

# Step 2: Create cloud-init
echo "[2/4] Creating cloud-init configuration..."
"${SCRIPT_DIR}/02-create-cloudinit.sh"
echo ""

# Step 3: Setup networking
echo "[3/4] Setting up networking..."
sudo "${SCRIPT_DIR}/03-setup-network.sh"
echo ""

# Step 4: Launch VM
echo "[4/4] Launching VM..."
echo ""
echo "============================================"
echo "  VM is starting..."
echo "  SSH: ssh cloud@192.168.100.2"
echo "  Password: cloud123"
echo "============================================"
echo ""

"${SCRIPT_DIR}/04-launch-vm.sh"
