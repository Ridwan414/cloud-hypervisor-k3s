#!/bin/bash
# Creates a VM with the specified ID
# Usage: vm-create.sh <VM_ID>
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"

# Validate arguments
if [[ -z "$1" ]]; then
    echo "Usage: $0 <VM_ID>"
    exit 1
fi

VM_ID="$1"

if ! [[ "$VM_ID" =~ ^[0-9]+$ ]] || [[ "$VM_ID" -lt 1 ]]; then
    echo "Error: VM_ID must be a positive integer"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: Run as root (sudo)"
    exit 1
fi

# VM configuration
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
WG_PORT=$((51820 + VM_ID))

echo "Creating VM ${VM_ID}: IP=${VM_IP}, TAP=${TAP_DEV}, WG_PORT=${WG_PORT}"

if [[ -d "${VM_DIR}" ]]; then
    echo "Error: VM ${VM_ID} already exists. Delete it first."
    exit 1
fi

# Find base image
ARCH=$(uname -m)
if [[ "${ARCH}" == "x86_64" ]]; then
    BASE_IMAGE="${VM_BASE_DIR}/jammy-server-cloudimg-amd64.raw"
elif [[ "${ARCH}" == "aarch64" ]]; then
    BASE_IMAGE="${VM_BASE_DIR}/jammy-server-cloudimg-arm64.raw"
else
    echo "Error: Unsupported architecture: ${ARCH}"
    exit 1
fi

if [[ ! -f "${BASE_IMAGE}" ]]; then
    echo "Error: Base image not found. Run 'make setup' first."
    exit 1
fi

# Create VM directory and disk
mkdir -p "${VM_DIR}"
cp --sparse=always "${BASE_IMAGE}" "${VM_DIR}/disk.raw"
qemu-img resize "${VM_DIR}/disk.raw" "${DISK_SIZE}"

# Get SSH key if available
SSH_KEY=""
for key_file in /home/*/.ssh/id_rsa.pub /home/*/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ed25519.pub; do
    if [[ -f "${key_file}" ]]; then
        SSH_KEY=$(cat "${key_file}")
        break
    fi
done

# Create cloud-init files
cat > "${VM_DIR}/meta-data" <<EOF
instance-id: ${VM_HOSTNAME}
local-hostname: ${VM_HOSTNAME}
EOF

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
package_update: true
packages:
  - wireguard-tools

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - curl -sL 'https://apt.netmaker.org/gpg.key' | sudo tee /etc/apt/trusted.gpg.d/netclient.asc
  - curl -sL 'https://apt.netmaker.org/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/netclient.list
  - apt-get update
  - apt-get install -y netclient
EOF

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
      addresses: [8.8.8.8, 8.8.4.4]
EOF

# Generate cloud-init ISO
command -v cloud-localds &>/dev/null || apt-get install -y -qq cloud-image-utils
cloud-localds -v --network-config="${VM_DIR}/network-config" "${VM_DIR}/cloudinit.img" "${VM_DIR}/user-data" "${VM_DIR}/meta-data"

# Setup bridge (shared by all VMs)
if ! ip link show "${BRIDGE_DEV}" &>/dev/null; then
    ip link add name "${BRIDGE_DEV}" type bridge
    ip addr add "${GATEWAY_IP}/24" dev "${BRIDGE_DEV}"
    ip link set "${BRIDGE_DEV}" up
fi

# Setup TAP device
if ip link show "${TAP_DEV}" &>/dev/null; then
    ip link set "${TAP_DEV}" down 2>/dev/null || true
    ip link set "${TAP_DEV}" nomaster 2>/dev/null || true
else
    ip tuntap add dev "${TAP_DEV}" mode tap
fi
ip link set "${TAP_DEV}" master "${BRIDGE_DEV}"
ip link set "${TAP_DEV}" up

# Setup NAT
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
sysctl -w net.ipv4.ip_forward=1 > /dev/null

iptables -t nat -C POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "${PRIMARY_IF}" -j MASQUERADE

iptables -C FORWARD -i "${BRIDGE_DEV}" -o "${PRIMARY_IF}" -j ACCEPT 2>/dev/null || {
    iptables -A FORWARD -i "${BRIDGE_DEV}" -o "${PRIMARY_IF}" -j ACCEPT
    iptables -A FORWARD -i "${PRIMARY_IF}" -o "${BRIDGE_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

# Setup WireGuard port forwarding
iptables -C FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT

iptables -t nat -C PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}"

# Save VM config
cat > "${VM_DIR}/vm.conf" <<EOF
VM_ID=${VM_ID}
VM_IP=${VM_IP}
TAP_DEV=${TAP_DEV}
MAC_ADDR=${MAC_ADDR}
VM_HOSTNAME=${VM_HOSTNAME}
VM_USER=${VM_USER}
WG_PORT=${WG_PORT}
EOF

# Fix ownership for non-root start
[[ -n "${SUDO_USER}" ]] && chown -R "${SUDO_USER}:${SUDO_USER}" "${VM_DIR}"

echo "VM ${VM_ID} created. Start with: make vm-start ID=${VM_ID}"
