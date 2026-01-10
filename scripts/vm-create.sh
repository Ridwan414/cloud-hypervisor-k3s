#!/bin/bash
# Creates a VM with the specified ID
# Usage: vm-create.sh <VM_ID>
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

# Validate VM_ID is a positive integer
if ! [[ "$VM_ID" =~ ^[0-9]+$ ]] || [[ "$VM_ID" -lt 1 ]]; then
    echo "Error: VM_ID must be a positive integer"
    exit 1
fi

# Check if running as root (needed for TAP device)
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

# Derive VM-specific values from ID
VM_DIR="${VM_BASE_DIR}/vm-${VM_ID}"
TAP_DEV="tap${VM_ID}"
BRIDGE_DEV="vmbridge"
VM_IP="192.168.100.$((VM_ID + 1))"
GATEWAY_IP="192.168.100.1"
MAC_ADDR=$(printf "12:34:56:78:9a:%02x" "$VM_ID")
VM_HOSTNAME="vm-${VM_ID}"
VM_USER="${VM_USER:-cloud}"
VM_PASSWORD="${VM_PASSWORD:-cloud123}"

DISK_SIZE="${DISK_SIZE:-10G}"

echo "=== Creating VM ${VM_ID} ==="
echo "Directory: ${VM_DIR}"
echo "Disk size: ${DISK_SIZE}"
echo "TAP device: ${TAP_DEV}"
echo "Bridge: ${BRIDGE_DEV}"
echo "IP address: ${VM_IP}"
echo "MAC address: ${MAC_ADDR}"
echo "Hostname: ${VM_HOSTNAME}"

# Check if VM already exists
if [[ -d "${VM_DIR}" ]]; then
    echo "Error: VM ${VM_ID} already exists at ${VM_DIR}"
    echo "Use 'make vm-delete ID=${VM_ID}' to remove it first"
    exit 1
fi

# Check for base image
ARCH=$(uname -m)
if [[ "${ARCH}" == "x86_64" ]]; then
    BASE_IMAGE="${VM_BASE_DIR}/jammy-server-cloudimg-amd64.raw"
elif [[ "${ARCH}" == "aarch64" ]]; then
    BASE_IMAGE="${VM_BASE_DIR}/jammy-server-cloudimg-arm64.raw"
else
    echo "Unsupported architecture: ${ARCH}"
    exit 1
fi

if [[ ! -f "${BASE_IMAGE}" ]]; then
    echo "Error: Base image not found: ${BASE_IMAGE}"
    echo "Run 'make setup' first"
    exit 1
fi

# Create VM directory
echo ""
echo "Creating VM directory..."
mkdir -p "${VM_DIR}"

# Copy base disk image
echo "Copying base disk image (this may take a moment)..."
cp --sparse=always "${BASE_IMAGE}" "${VM_DIR}/disk.raw"

# Resize disk to specified size
echo "Resizing disk to ${DISK_SIZE}..."
qemu-img resize "${VM_DIR}/disk.raw" "${DISK_SIZE}"

# Get SSH public key if available
SSH_KEY=""
for key_file in /home/*/.ssh/id_rsa.pub /home/*/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ed25519.pub; do
    if [[ -f "${key_file}" ]]; then
        SSH_KEY=$(cat "${key_file}")
        break
    fi
done

# Create cloud-init meta-data
echo "Creating cloud-init configuration..."
cat > "${VM_DIR}/meta-data" <<EOF
instance-id: ${VM_HOSTNAME}
local-hostname: ${VM_HOSTNAME}
EOF

# Create cloud-init user-data
cat > "${VM_DIR}/user-data" <<EOF
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
    cat >> "${VM_DIR}/user-data" <<EOF
    ssh_authorized_keys:
      - ${SSH_KEY}
EOF
fi

cat >> "${VM_DIR}/user-data" <<EOF

ssh_pwauth: true

package_update: false

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - echo "VM ${VM_ID} is ready" > /var/log/vm-ready.log
EOF

# Create cloud-init network-config
cat > "${VM_DIR}/network-config" <<EOF
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

# Generate cloud-init ISO
if ! command -v cloud-localds &> /dev/null; then
    echo "Installing cloud-image-utils..."
    apt-get update -qq
    apt-get install -y -qq cloud-image-utils
fi

cloud-localds -v --network-config="${VM_DIR}/network-config" "${VM_DIR}/cloudinit.img" "${VM_DIR}/user-data" "${VM_DIR}/meta-data"

# Setup bridge device (shared by all VMs)
echo ""
echo "Setting up bridge ${BRIDGE_DEV}..."

if ! ip link show "${BRIDGE_DEV}" &>/dev/null; then
    echo "Creating bridge ${BRIDGE_DEV}..."
    ip link add name "${BRIDGE_DEV}" type bridge
    ip addr add "${GATEWAY_IP}/24" dev "${BRIDGE_DEV}"
    ip link set "${BRIDGE_DEV}" up
else
    echo "Bridge ${BRIDGE_DEV} already exists"
fi

# Setup TAP device
echo "Setting up TAP device ${TAP_DEV}..."

# Create TAP device if it doesn't exist
if ip link show "${TAP_DEV}" &>/dev/null; then
    echo "TAP device ${TAP_DEV} already exists, reconfiguring..."
    ip link set "${TAP_DEV}" down 2>/dev/null || true
    ip link set "${TAP_DEV}" nomaster 2>/dev/null || true
else
    ip tuntap add dev "${TAP_DEV}" mode tap
fi

# Add TAP to bridge (no IP on TAP - bridge has the IP)
ip link set "${TAP_DEV}" master "${BRIDGE_DEV}"
ip link set "${TAP_DEV}" up

# Detect primary network interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Setup NAT rules (check if already exists)
if ! iptables -t nat -C POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE
fi

if ! iptables -C FORWARD -i "${BRIDGE_DEV}" -o "${PRIMARY_IF}" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "${BRIDGE_DEV}" -o "${PRIMARY_IF}" -j ACCEPT
    iptables -A FORWARD -i "${PRIMARY_IF}" -o "${BRIDGE_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# Save VM metadata
cat > "${VM_DIR}/vm.conf" <<EOF
VM_ID=${VM_ID}
VM_IP=${VM_IP}
TAP_DEV=${TAP_DEV}
MAC_ADDR=${MAC_ADDR}
VM_HOSTNAME=${VM_HOSTNAME}
VM_USER=${VM_USER}
EOF

# Change ownership of VM directory to the invoking user (so vm-start can write PID file)
if [[ -n "${SUDO_USER}" ]]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${VM_DIR}"
fi

echo ""
echo "=== VM ${VM_ID} Created Successfully ==="
echo ""
echo "To start the VM:  make vm-start ID=${VM_ID}"
echo "To SSH into it:   make vm-ssh ID=${VM_ID}"
echo "                  ssh ${VM_USER}@${VM_IP} (password: ${VM_PASSWORD})"
