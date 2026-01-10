# Cloud Hypervisor VM Launch Guide

This document explains how to launch a virtual machine using cloud-hypervisor and details what happens at each step.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Step-by-Step Process](#step-by-step-process)
4. [What Happens Under the Hood](#what-happens-under-the-hood)
5. [Troubleshooting](#troubleshooting)

---

## Overview

Cloud Hypervisor is a lightweight Virtual Machine Monitor (VMM) written in Rust. It uses Linux KVM (Kernel-based Virtual Machine) to run virtual machines with near-native performance.

### Key Components

```
┌─────────────────────────────────────────────────────────────┐
│                        HOST SYSTEM                          │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                  Cloud Hypervisor (VMM)               │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐   │  │
│  │  │   vCPUs     │  │   Memory    │  │   Devices    │   │  │
│  │  │  (KVM)      │  │  (2048M)    │  │  (virtio)    │   │  │
│  │  └─────────────┘  └─────────────┘  └──────────────┘   │  │
│  └───────────────────────────────────────────────────────┘  │
│                            │                                 │
│                      ┌─────┴─────┐                          │
│                      │   /dev/kvm │                          │
│                      └───────────┘                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ TAP Device  │  │ Disk Image  │  │  Cloud-Init ISO     │  │
│  │   (tap0)    │  │  (.raw)     │  │  (cloudinit.img)    │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Architecture

### Components Required

| Component | Purpose | File |
|-----------|---------|------|
| **Cloud Hypervisor** | VMM binary that manages the VM | `cloud-hypervisor` |
| **Firmware** | UEFI-like boot firmware | `hypervisor-fw` |
| **Disk Image** | Root filesystem (Ubuntu) | `jammy-server-cloudimg-amd64.raw` |
| **Cloud-Init** | VM initialization config | `cloudinit.img` |
| **TAP Device** | Network bridge to host | `tap0` |

### Network Topology

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────┐
│       VM         │     │    TAP Bridge    │     │   Internet   │
│  192.168.100.2   │◄───►│  192.168.100.1   │◄───►│   (via NAT)  │
│    (ens4)        │     │     (tap0)       │     │    (eno1)    │
└──────────────────┘     └──────────────────┘     └──────────────┘
         │                        │
         │    virtio-net          │    iptables MASQUERADE
         └────────────────────────┘
```

---

## Step-by-Step Process

### Step 1: Setup (`01-setup.sh`)

**What it does:**
Downloads the required binaries and images.

```bash
./scripts/01-setup.sh
```

**Actions performed:**

1. **Download cloud-hypervisor binary**
   ```
   https://github.com/cloud-hypervisor/cloud-hypervisor/releases/latest/download/cloud-hypervisor-static
   ```
   - Pre-compiled static binary
   - No dependencies required
   - ~5MB in size

2. **Download hypervisor firmware**
   ```
   https://github.com/cloud-hypervisor/rust-hypervisor-firmware/releases/download/0.4.2/hypervisor-fw
   ```
   - Rust-based UEFI firmware
   - Provides boot services to load OS from disk
   - ~90KB in size

3. **Download Ubuntu cloud image**
   ```
   https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
   ```
   - Pre-built Ubuntu 22.04 image
   - QCOW2 format (~660MB)

4. **Convert QCOW2 to RAW format**
   ```bash
   qemu-img convert -f qcow2 -O raw image.img image.raw
   ```
   - Cloud-hypervisor requires RAW disk format
   - RAW provides better performance (no QCOW2 overhead)
   - Resulting size: ~2.2GB (sparse file)

---

### Step 2: Create Cloud-Init (`02-create-cloudinit.sh`)

**What it does:**
Creates the cloud-init configuration that initializes the VM on first boot.

```bash
./scripts/02-create-cloudinit.sh
```

**Cloud-init is the industry standard for VM initialization.** It runs on first boot and configures:

#### 2.1 meta-data
```yaml
instance-id: cloud-hypervisor-vm
local-hostname: cloud-hypervisor-vm
```
- **instance-id**: Unique identifier (changing this triggers re-initialization)
- **local-hostname**: Sets the VM's hostname

#### 2.2 user-data
```yaml
#cloud-config
users:
  - name: cloud
    sudo: ALL=(ALL) NOPASSWD:ALL
    plain_text_passwd: cloud123
    ssh_authorized_keys:
      - ssh-rsa AAAA...

ssh_pwauth: true
```
- **users**: Creates the `cloud` user with sudo access
- **ssh_pwauth**: Enables password authentication for SSH
- **ssh_authorized_keys**: Adds your public key for key-based auth

#### 2.3 network-config
```yaml
version: 2
ethernets:
  eth0:
    match:
      driver: virtio_net
    addresses:
      - 192.168.100.2/24
    routes:
      - to: default
        via: 192.168.100.1
    nameservers:
      addresses: [8.8.8.8, 8.8.4.4]
```
- **match.driver**: Matches any virtio network interface
- **addresses**: Static IP for the VM
- **routes**: Default gateway (host's TAP IP)
- **nameservers**: DNS servers

#### 2.4 Generate ISO
```bash
cloud-localds cloudinit.img user-data meta-data --network-config=network-config
```
- Creates an ISO9660 filesystem image
- VM mounts this as a CD-ROM drive
- Cloud-init reads config from the mounted ISO

---

### Step 3: Setup Networking (`03-setup-network.sh`)

**What it does:**
Creates the virtual network infrastructure on the host.

```bash
sudo ./scripts/03-setup-network.sh
```

**Actions performed:**

#### 3.1 Create TAP Device
```bash
ip tuntap add dev tap0 mode tap
ip addr add 192.168.100.1/24 dev tap0
ip link set tap0 up
```

**What is a TAP device?**
- TAP (Network TAP) is a virtual network interface
- Operates at Layer 2 (Ethernet frames)
- Acts as a bridge between the VM and host network stack
- Cloud-hypervisor attaches VM's virtio-net to this TAP device

```
VM Network Stack          Host Network Stack
      │                         │
      ▼                         ▼
┌──────────┐              ┌──────────┐
│  ens4    │◄────────────►│  tap0    │
│(virtio)  │   Ethernet   │  (TAP)   │
└──────────┘    Frames    └──────────┘
```

#### 3.2 Enable IP Forwarding
```bash
sysctl -w net.ipv4.ip_forward=1
```
- Allows the host to route packets between interfaces
- Required for VM to reach external networks

#### 3.3 Setup NAT (Network Address Translation)
```bash
iptables -t nat -A POSTROUTING -o eno1 -j MASQUERADE
iptables -A FORWARD -i tap0 -o eno1 -j ACCEPT
iptables -A FORWARD -i eno1 -o tap0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

**Packet flow for VM → Internet:**
```
1. VM (192.168.100.2) sends packet to 8.8.8.8
2. Packet arrives at tap0 on host
3. Host forwards packet to eno1 (ip_forward=1)
4. MASQUERADE rewrites source IP to host's public IP
5. Response comes back, NAT translates back to VM IP
6. Packet forwarded back through tap0 to VM
```

---

### Step 4: Launch VM (`04-launch-vm.sh`)

**What it does:**
Starts the cloud-hypervisor process which creates and runs the VM.

```bash
./scripts/04-launch-vm.sh
```

**The launch command:**
```bash
./cloud-hypervisor \
    --firmware ./hypervisor-fw \
    --disk path=jammy-server-cloudimg-amd64.raw path=cloudinit.img \
    --cpus boot=2 \
    --memory size=2048M \
    --net tap=tap0,mac=12:34:56:78:9a:bc
```

#### Parameter Breakdown

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `--firmware` | `hypervisor-fw` | UEFI firmware for boot |
| `--disk` | `image.raw cloudinit.img` | Root disk + cloud-init ISO |
| `--cpus` | `boot=2` | 2 virtual CPUs |
| `--memory` | `size=2048M` | 2GB RAM |
| `--net` | `tap=tap0,mac=...` | Network via TAP device |

---

## What Happens Under the Hood

### Boot Sequence Timeline

```
Time    Event
─────────────────────────────────────────────────────────────
0ms     cloud-hypervisor starts
        ├── Opens /dev/kvm
        ├── Creates VM with KVM_CREATE_VM ioctl
        ├── Allocates 2GB memory region
        └── Creates 2 vCPUs with KVM_CREATE_VCPU

5ms     Device initialization
        ├── Creates virtio-blk for disk image
        ├── Creates virtio-blk for cloudinit.img
        ├── Creates virtio-net attached to tap0
        └── Creates virtio-console for serial output

10ms    Firmware loaded into guest memory
        └── hypervisor-fw loaded at reset vector

15ms    vCPUs start executing
        └── Firmware begins execution

100ms   Firmware initializes
        ├── Detects virtio devices
        ├── Finds bootable disk
        └── Loads GRUB bootloader from disk

500ms   GRUB starts
        ├── Reads grub.cfg
        └── Loads Linux kernel + initramfs

2s      Linux kernel boots
        ├── Initializes virtio drivers
        ├── Mounts initramfs
        └── Starts systemd

5s      systemd starts services
        ├── cloud-init-local.service
        ├── cloud-init.service
        └── cloud-init-network.service

10s     cloud-init runs
        ├── Reads meta-data from /dev/vdb (cloudinit.img)
        ├── Creates user 'cloud'
        ├── Configures network (netplan apply)
        └── Starts SSH daemon

15s     VM ready for SSH
        └── ssh cloud@192.168.100.2
```

### KVM Interaction

Cloud-hypervisor uses KVM through these key ioctls:

```c
// 1. Create VM
int vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);

// 2. Allocate memory
struct kvm_userspace_memory_region region = {
    .slot = 0,
    .guest_phys_addr = 0,
    .memory_size = 2ULL * 1024 * 1024 * 1024,  // 2GB
    .userspace_addr = (uint64_t)mmap(...)
};
ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region);

// 3. Create vCPU
int vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, cpu_id);

// 4. Run vCPU (main loop)
while (running) {
    ioctl(vcpu_fd, KVM_RUN, NULL);
    // Handle VM exits (I/O, MMIO, etc.)
}
```

### Virtio Device Model

Cloud-hypervisor uses **virtio** for all device emulation:

```
┌─────────────────────────────────────────────────────────┐
│                    Guest (VM)                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │ virtio-blk  │  │ virtio-net  │  │ virtio-console  │  │
│  │   driver    │  │   driver    │  │     driver      │  │
│  └──────┬──────┘  └──────┬──────┘  └────────┬────────┘  │
│         │                │                  │           │
│         │    virtqueues  │                  │           │
│         │    (shared     │                  │           │
│         │     memory)    │                  │           │
└─────────┼────────────────┼──────────────────┼───────────┘
          │                │                  │
┌─────────┼────────────────┼──────────────────┼───────────┐
│         │                │                  │           │
│  ┌──────┴──────┐  ┌──────┴──────┐  ┌────────┴────────┐  │
│  │ virtio-blk  │  │ virtio-net  │  │ virtio-console  │  │
│  │   backend   │  │   backend   │  │     backend     │  │
│  └──────┬──────┘  └──────┬──────┘  └────────┬────────┘  │
│         │                │                  │           │
│         ▼                ▼                  ▼           │
│    disk.raw          tap0              stdout          │
│                   Cloud Hypervisor (Host)               │
└─────────────────────────────────────────────────────────┘
```

**Why virtio?**
- Paravirtualized (guest knows it's in a VM)
- Much faster than emulating real hardware
- Uses shared memory rings (virtqueues) for efficiency
- No need to emulate legacy hardware (IDE, e1000, etc.)

---

## Troubleshooting

### Common Issues

#### 1. Permission denied on /dev/kvm
```bash
# Add user to kvm group
sudo usermod -aG kvm $USER
# Or temporarily fix permissions
sudo chmod 666 /dev/kvm
```

#### 2. TAP device busy
```bash
# Kill any stuck cloud-hypervisor processes
pkill -9 cloud-hypervisor
# Recreate TAP device
sudo ip link del tap0
sudo ./scripts/03-setup-network.sh
```

#### 3. Disk image locked
```bash
# Remove lock and reconvert image
rm -f vm/*.raw
cd vm && qemu-img convert -f qcow2 -O raw image.img image.raw
```

#### 4. VM not reachable via network
```bash
# Check TAP device is up
ip addr show tap0

# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward  # Should be 1

# Check iptables rules
sudo iptables -t nat -L -n -v
sudo iptables -L FORWARD -n -v
```

#### 5. Cloud-init not running
```bash
# SSH in (if possible) and check logs
sudo cat /var/log/cloud-init.log
sudo cat /var/log/cloud-init-output.log

# Check if cloud-init was triggered
ls -la /var/lib/cloud/instance/
```

---

## Quick Reference

### Start VM
```bash
cd /home/ubuntu/cv-k3s-poc
./scripts/run-all.sh
```

### SSH into VM
```bash
ssh cloud@192.168.100.2
# Password: cloud123
```

### Stop VM
```bash
pkill cloud-hypervisor
```

### Cleanup
```bash
sudo ./scripts/cleanup.sh
```

### Full Reset
```bash
pkill -9 cloud-hypervisor
sudo ./scripts/cleanup.sh
rm -f vm/*.raw vm/cloudinit.img
./scripts/01-setup.sh
./scripts/02-create-cloudinit.sh
sudo ./scripts/03-setup-network.sh
./scripts/04-launch-vm.sh
```
