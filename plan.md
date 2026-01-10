# Cloud Hypervisor VM Launch and SSH Plan

## Overview

This plan covers launching a virtual machine using [cloud-hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) and establishing SSH access.

---

## Prerequisites

- Linux host with kernel 5.13+ (5.15 recommended)
- KVM enabled (`/dev/kvm` accessible)
- `qemu-img` for image conversion
- `wget` or `curl` for downloads
- Root or appropriate capabilities for TAP networking

### Verify KVM Support

```bash
ls -la /dev/kvm
lsmod | grep kvm
```

---

## Step 1: Install Cloud Hypervisor

### Option A: Pre-built Binary (Recommended)

```bash
# x86-64
wget https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static
chmod +x cloud-hypervisor-static
sudo mv cloud-hypervisor-static /usr/local/bin/cloud-hypervisor

# AArch64
wget https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static-aarch64
chmod +x cloud-hypervisor-static-aarch64
sudo mv cloud-hypervisor-static-aarch64 /usr/local/bin/cloud-hypervisor
```

### Option B: Build from Source

See: https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/building.md

---

## Step 2: Download Required Images

### 2.1 Download Firmware

```bash
mkdir -p ~/cloud-hypervisor-vm && cd ~/cloud-hypervisor-vm

# Rust Hypervisor Firmware
wget https://github.com/cloud-hypervisor/rust-hypervisor-firmware/releases/download/0.4.2/hypervisor-fw
```

### 2.2 Download and Convert Cloud Image

```bash
# Ubuntu 22.04 (Jammy) - x86-64
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img

# Convert QCOW2 to raw format (required by cloud-hypervisor)
qemu-img convert -p -f qcow2 -O raw jammy-server-cloudimg-amd64.img jammy-server-cloudimg-amd64.raw
```

---

## Step 3: Create Cloud-Init Configuration

Cloud-init is required to set up user credentials and networking for SSH access.

### 3.1 Create meta-data

```bash
cat > meta-data <<EOF
instance-id: cloud-hypervisor-vm
local-hostname: cloud-hypervisor-vm
EOF
```

### 3.2 Create user-data

```bash
cat > user-data <<EOF
#cloud-config
users:
  - name: cloud
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: cloud123
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "ssh-rsa YOUR_PUBLIC_KEY_HERE")

ssh_pwauth: true

package_update: true
packages:
  - openssh-server

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
EOF
```

### 3.3 Create network-config

```bash
cat > network-config <<EOF
version: 2
ethernets:
  enp0s3:
    dhcp4: false
    addresses:
      - 192.168.100.2/24
    gateway4: 192.168.100.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF
```

### 3.4 Generate Cloud-Init ISO

```bash
# Install cloud-image-utils if needed
sudo apt-get install -y cloud-image-utils

# Create the cloud-init ISO
cloud-localds -v --network-config=network-config cloudinit.img user-data meta-data
```

---

## Step 4: Set Up Host Networking (TAP Device)

### 4.1 Create TAP Interface

```bash
# Create TAP device
sudo ip tuntap add dev tap0 mode tap
sudo ip addr add 192.168.100.1/24 dev tap0
sudo ip link set tap0 up
```

### 4.2 Enable IP Forwarding and NAT (for internet access)

```bash
# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1

# Set up NAT (replace eth0 with your actual interface)
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i tap0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tap0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

---

## Step 5: Grant Network Capabilities

```bash
# Allow cloud-hypervisor to manage TAP devices without root
sudo setcap cap_net_admin+ep /usr/local/bin/cloud-hypervisor
```

---

## Step 6: Launch the VM

### Option A: Using Firmware (UEFI-like boot)

```bash
cloud-hypervisor \
    --firmware ./hypervisor-fw \
    --disk path=jammy-server-cloudimg-amd64.raw path=cloudinit.img \
    --cpus boot=2 \
    --memory size=2048M \
    --net tap=tap0,mac=12:34:56:78:9a:bc,ip=,mask=
```

### Option B: Using Direct Kernel Boot

First, download a compatible kernel:

```bash
# Clone and build kernel (optional - for custom kernel)
git clone --depth 1 https://github.com/cloud-hypervisor/linux.git -b ch-6.12.8 linux-cloud-hypervisor
cd linux-cloud-hypervisor
make ch_defconfig
KCFLAGS="-Wa,-mx86-used-note=no" make bzImage -j $(nproc)
cd ..
```

Then launch:

```bash
cloud-hypervisor \
    --kernel ./linux-cloud-hypervisor/arch/x86/boot/compressed/vmlinux.bin \
    --disk path=jammy-server-cloudimg-amd64.raw path=cloudinit.img \
    --cmdline "console=hvc0 root=/dev/vda1 rw" \
    --cpus boot=2 \
    --memory size=2048M \
    --net tap=tap0,mac=12:34:56:78:9a:bc,ip=,mask=
```

---

## Step 7: SSH into the VM

Wait for the VM to boot (observe console output), then:

```bash
# SSH using password (cloud123)
ssh cloud@192.168.100.2

# Or using SSH key if configured
ssh -i ~/.ssh/id_rsa cloud@192.168.100.2
```

**Default credentials:**
- Username: `cloud`
- Password: `cloud123`

---

## Troubleshooting

### VM console not accessible
Add `--serial tty --console off` to use serial console instead of virtio console.

### Network not working
1. Verify TAP device exists: `ip addr show tap0`
2. Check IP forwarding: `cat /proc/sys/net/ipv4/ip_forward`
3. Verify iptables rules: `sudo iptables -L -n -v`

### Permission denied on /dev/kvm
```bash
sudo usermod -aG kvm $USER
# Log out and back in
```

### Cannot create TAP device
Ensure you have `cap_net_admin` capability or run with sudo.

---

## Quick Start Script

Save as `launch-vm.sh`:

```bash
#!/bin/bash
set -e

VM_DIR=~/cloud-hypervisor-vm
cd $VM_DIR

# Ensure TAP device exists
if ! ip link show tap0 &>/dev/null; then
    sudo ip tuntap add dev tap0 mode tap
    sudo ip addr add 192.168.100.1/24 dev tap0
    sudo ip link set tap0 up
fi

# Launch VM
cloud-hypervisor \
    --firmware ./hypervisor-fw \
    --disk path=jammy-server-cloudimg-amd64.raw path=cloudinit.img \
    --cpus boot=2 \
    --memory size=2048M \
    --net tap=tap0,mac=12:34:56:78:9a:bc,ip=,mask=
```

---

## References

- [Cloud Hypervisor GitHub](https://github.com/cloud-hypervisor/cloud-hypervisor)
- [Cloud Hypervisor Documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/tree/main/docs)
- [Rust Hypervisor Firmware](https://github.com/cloud-hypervisor/rust-hypervisor-firmware)
- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/)
