#!/bin/bash
# Creates cloud-init configuration for the VM
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="${SCRIPT_DIR}/../vm"

echo "=== Creating Cloud-Init Configuration ==="

mkdir -p "${VM_DIR}"
cd "${VM_DIR}"

# VM Network config
VM_IP="${VM_IP:-192.168.100.2}"
GATEWAY_IP="${GATEWAY_IP:-192.168.100.1}"
VM_USER="${VM_USER:-cloud}"
VM_PASSWORD="${VM_PASSWORD:-cloud123}"

echo "VM IP: ${VM_IP}"
echo "Gateway: ${GATEWAY_IP}"
echo "User: ${VM_USER}"

# Create meta-data
cat > meta-data <<EOF
instance-id: cloud-hypervisor-vm
local-hostname: cloud-hypervisor-vm
EOF
echo "Created meta-data"

# Get SSH public key if available
SSH_KEY=""
if [[ -f ~/.ssh/id_rsa.pub ]]; then
    SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
elif [[ -f ~/.ssh/id_ed25519.pub ]]; then
    SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
fi

# Create user-data
cat > user-data <<EOF
#cloud-config
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${VM_PASSWORD}
EOF

if [[ -n "${SSH_KEY}" ]]; then
    cat >> user-data <<EOF
    ssh_authorized_keys:
      - ${SSH_KEY}
EOF
    echo "Added SSH key to user-data"
fi

cat >> user-data <<EOF

ssh_pwauth: true

package_update: false

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - echo "VM is ready for SSH" > /var/log/vm-ready.log
EOF
echo "Created user-data"

# Create network-config (use match by driver for virtio-net)
cat > network-config <<EOF
version: 2
ethernets:
  eth0:
    match:
      driver: virtio_net
    dhcp4: false
    addresses:
      - ${VM_IP}/24
    routes:
      - to: default
        via: ${GATEWAY_IP}
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF
echo "Created network-config"

# Check for cloud-localds
if ! command -v cloud-localds &> /dev/null; then
    echo "Installing cloud-image-utils..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq cloud-image-utils
fi

# Generate cloud-init ISO
echo "Generating cloud-init ISO..."
cloud-localds -v --network-config=network-config cloudinit.img user-data meta-data

echo ""
echo "=== Cloud-Init Configuration Complete ==="
echo "Generated: ${VM_DIR}/cloudinit.img"
ls -lh cloudinit.img
