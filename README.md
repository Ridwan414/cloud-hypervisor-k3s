# Cloud Hypervisor VM PoC

A proof-of-concept for launching virtual machines using [Cloud Hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) - a lightweight, Rust-based VMM (Virtual Machine Monitor).

## Overview

This project provides scripts to:
- Download and set up Cloud Hypervisor
- Create and configure Ubuntu VMs with cloud-init
- Set up TAP networking for SSH access
- Launch VMs with a single command

## Prerequisites

- Linux host with KVM support
- Kernel 5.13+ (5.15 recommended)
- `qemu-img` for image conversion
- Root/sudo access for networking setup

```bash
# Verify KVM support
ls -la /dev/kvm

# Install dependencies (Ubuntu/Debian)
sudo apt-get install qemu-utils cloud-image-utils
```

## Quick Start

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/cv-k3s-poc.git
cd cv-k3s-poc

# Run everything (downloads ~700MB on first run)
./scripts/run-all.sh

# SSH into the VM (from another terminal)
ssh cloud@192.168.100.2
# Password: cloud123
```

## Scripts

| Script | Purpose | Sudo |
|--------|---------|------|
| `01-setup.sh` | Download cloud-hypervisor, firmware, Ubuntu image | No |
| `02-create-cloudinit.sh` | Generate cloud-init config (user, network) | No |
| `03-setup-network.sh` | Create TAP device, enable NAT | Yes |
| `04-launch-vm.sh` | Launch the VM | No |
| `05-ssh-vm.sh` | SSH into running VM | No |
| `run-all.sh` | Run all steps in sequence | Yes |
| `cleanup.sh` | Remove TAP device and iptables rules | Yes |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      HOST SYSTEM                        │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │              Cloud Hypervisor (VMM)               │  │
│  │                                                   │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────────────┐   │  │
│  │  │ 2 vCPUs │  │ 2GB RAM │  │ virtio devices  │   │  │
│  │  └─────────┘  └─────────┘  └─────────────────┘   │  │
│  └───────────────────────────────────────────────────┘  │
│                          │                              │
│                    ┌─────┴─────┐                        │
│                    │  /dev/kvm │                        │
│                    └───────────┘                        │
│                                                         │
│  ┌──────────────┐    ┌──────────────────────────────┐  │
│  │ TAP (tap0)   │    │ Disk: Ubuntu 22.04 (raw)     │  │
│  │192.168.100.1 │    │ Cloud-init: user + network   │  │
│  └──────────────┘    └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘

Network: VM (192.168.100.2) ←→ TAP (192.168.100.1) ←→ NAT ←→ Internet
```

## VM Credentials

| Field | Value |
|-------|-------|
| Username | `cloud` |
| Password | `cloud123` |
| IP Address | `192.168.100.2` |
| SSH | `ssh cloud@192.168.100.2` |

## Configuration

Environment variables can customize the VM:

```bash
# Cloud-init config
VM_IP=192.168.100.2        # VM IP address
GATEWAY_IP=192.168.100.1   # Gateway (TAP IP)
VM_USER=cloud              # Username
VM_PASSWORD=cloud123       # Password

# VM resources
CPUS=2                     # Number of vCPUs
MEMORY=2048M               # RAM size

# Network
TAP_DEV=tap0               # TAP device name
MAC_ADDR=12:34:56:78:9a:bc # VM MAC address

# Boot mode
BOOT_MODE=firmware         # 'firmware' or 'kernel'
```

Example:
```bash
CPUS=4 MEMORY=4096M ./scripts/04-launch-vm.sh
```

## Documentation

See [docs/cloud-hypervisor-guide.md](docs/cloud-hypervisor-guide.md) for:
- Detailed explanation of each step
- Boot sequence timeline
- KVM and virtio internals
- Troubleshooting guide

## Troubleshooting

### Permission denied on /dev/kvm
```bash
sudo usermod -aG kvm $USER
# Log out and back in
```

### VM not reachable
```bash
# Check TAP device
ip addr show tap0

# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward
```

### Disk locked error
```bash
pkill -9 cloud-hypervisor
rm -f vm/*.raw
./scripts/01-setup.sh  # Re-downloads and converts image
```

### Full reset
```bash
pkill -9 cloud-hypervisor
sudo ./scripts/cleanup.sh
rm -rf vm/
./scripts/run-all.sh
```

## Project Structure

```
cv-k3s-poc/
├── README.md
├── .gitignore
├── plan.md                      # Implementation plan
├── docs/
│   └── cloud-hypervisor-guide.md
├── scripts/
│   ├── 01-setup.sh
│   ├── 02-create-cloudinit.sh
│   ├── 03-setup-network.sh
│   ├── 04-launch-vm.sh
│   ├── 05-ssh-vm.sh
│   ├── run-all.sh
│   └── cleanup.sh
└── vm/                          # Created by scripts (gitignored)
    ├── cloud-hypervisor
    ├── hypervisor-fw
    ├── jammy-server-cloudimg-amd64.raw
    └── cloudinit.img
```

## References

- [Cloud Hypervisor GitHub](https://github.com/cloud-hypervisor/cloud-hypervisor)
- [Rust Hypervisor Firmware](https://github.com/cloud-hypervisor/rust-hypervisor-firmware)
- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/)
- [Cloud-init Documentation](https://cloudinit.readthedocs.io/)

## License

MIT
# cloud-hypervisor-k3s-poc
