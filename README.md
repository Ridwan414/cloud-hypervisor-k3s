# Cloud Hypervisor VM PoC

A proof-of-concept for launching multiple virtual machines using [Cloud Hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) - a lightweight, Rust-based VMM (Virtual Machine Monitor).

## Overview

This project provides a Makefile-based interface to:
- Download and set up Cloud Hypervisor
- Create and manage multiple Ubuntu VMs with cloud-init
- Set up bridge networking for VM communication
- Launch, stop, and delete VMs with simple commands

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
# Initial setup (downloads ~700MB on first run)
make setup

# Create and start a VM
make vm-create ID=1
make vm-start ID=1    # Runs in foreground, Ctrl+C to stop

# In another terminal, SSH into the VM
make vm-ssh ID=1
# Or: ssh cloud@192.168.100.2 (password: cloud123)
```

## Makefile Commands

| Command | Description | Sudo |
|---------|-------------|------|
| `make setup` | Download cloud-hypervisor, firmware, Ubuntu image | No |
| `make vm-create ID=N` | Create VM N (disk, cloud-init, networking) | Yes |
| `make vm-start ID=N` | Start VM N (foreground) | No |
| `make vm-stop ID=N` | Stop VM N | No |
| `make vm-delete ID=N` | Delete VM N and cleanup resources | Yes |
| `make vm-ssh ID=N` | SSH into VM N | No |
| `make vm-list` | List all VMs and their status | No |
| `make clean` | Stop all VMs, remove all resources | Yes |
| `make help` | Show available commands | No |

## Multi-VM Example

```bash
# Setup (first time only)
make setup

# Create multiple VMs
make vm-create ID=1    # IP: 192.168.100.2
make vm-create ID=2    # IP: 192.168.100.3
make vm-create ID=3    # IP: 192.168.100.4

# Start VMs (each in a separate terminal, or background with &)
make vm-start ID=1 &
make vm-start ID=2 &
make vm-start ID=3 &

# Check status
make vm-list

# SSH into VMs
make vm-ssh ID=1
make vm-ssh ID=2

# Stop and delete
make vm-stop ID=1
make vm-delete ID=1

# Cleanup everything
make clean
```

## VM Addressing

Each VM gets unique resources based on its ID:

| ID | IP Address | TAP Device | MAC Address |
|----|------------|------------|-------------|
| 1 | 192.168.100.2 | tap1 | 12:34:56:78:9a:01 |
| 2 | 192.168.100.3 | tap2 | 12:34:56:78:9a:02 |
| 3 | 192.168.100.4 | tap3 | 12:34:56:78:9a:03 |
| N | 192.168.100.(N+1) | tapN | 12:34:56:78:9a:XX |

## VM Credentials

| Field | Value |
|-------|-------|
| Username | `cloud` |
| Password | `cloud123` |
| SSH | `ssh cloud@192.168.100.<ID+1>` |

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         HOST SYSTEM                               │
│                                                                   │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐   │
│  │ cloud-hypervisor│  │ cloud-hypervisor│  │ cloud-hypervisor│   │
│  │     (VM 1)      │  │     (VM 2)      │  │     (VM 3)      │   │
│  │  192.168.100.2  │  │  192.168.100.3  │  │  192.168.100.4  │   │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘   │
│           │                    │                    │             │
│       ┌───┴───┐            ┌───┴───┐            ┌───┴───┐        │
│       │ tap1  │            │ tap2  │            │ tap3  │        │
│       └───┬───┘            └───┬───┘            └───┬───┘        │
│           │                    │                    │             │
│           └────────────────────┼────────────────────┘             │
│                                │                                  │
│                    ┌───────────┴───────────┐                      │
│                    │      vmbridge         │                      │
│                    │    192.168.100.1      │                      │
│                    └───────────┬───────────┘                      │
│                                │                                  │
│                          ┌─────┴─────┐                            │
│                          │    NAT    │                            │
│                          └─────┬─────┘                            │
│                                │                                  │
└────────────────────────────────┼──────────────────────────────────┘
                                 │
                            Internet
```

## Configuration

Environment variables can customize VMs:

```bash
# VM resources (set before vm-start)
CPUS=4 MEMORY=4096M make vm-start ID=1

# Boot mode
BOOT_MODE=firmware    # 'firmware' (default) or 'kernel'
```

## Documentation

- [Multi-VM Architecture](docs/multi-vm-architecture.md) - How the multi-VM system works
- [Cloud Hypervisor Guide](docs/cloud-hypervisor-guide.md) - Detailed internals and troubleshooting

## Troubleshooting

### Permission denied on /dev/kvm
```bash
sudo usermod -aG kvm $USER
# Log out and back in
```

### VM not reachable
```bash
# Check bridge and TAP devices
ip addr show vmbridge
bridge link show

# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward
```

### TAP device busy error
```bash
# Stop all VMs and recreate
make vm-stop ID=N
make vm-delete ID=N
make vm-create ID=N
```

### Full reset
```bash
make clean
rm -rf vm/
make setup
```

## Project Structure

```
cloud-hypervisor-k3s-poc/
├── Makefile                     # Main interface
├── README.md
├── docs/
│   ├── cloud-hypervisor-guide.md
│   └── multi-vm-architecture.md
├── scripts/
│   ├── 01-setup.sh              # Download binaries and images
│   ├── vm-create.sh             # Create VM (disk, cloud-init, TAP)
│   ├── vm-start.sh              # Start a VM
│   ├── vm-stop.sh               # Stop a VM
│   ├── vm-delete.sh             # Delete a VM
│   ├── vm-list.sh               # List all VMs
│   ├── vm-ssh.sh                # SSH into a VM
│   └── cleanup.sh               # Remove all VMs and networking
└── vm/                          # Created by scripts (gitignored)
    ├── cloud-hypervisor         # VMM binary
    ├── hypervisor-fw            # UEFI firmware
    ├── jammy-server-cloudimg-amd64.raw  # Base image
    ├── vm-1/                    # VM 1 directory
    │   ├── disk.raw             # VM disk (copy of base)
    │   ├── cloudinit.img        # Cloud-init ISO
    │   └── vm.conf              # VM configuration
    └── vm-2/                    # VM 2 directory
        └── ...
```

## Legacy Scripts

The original single-VM scripts are still available:

| Script | Purpose |
|--------|---------|
| `02-create-cloudinit.sh` | Generate single-VM cloud-init |
| `03-setup-network.sh` | Create single TAP device |
| `04-launch-vm.sh` | Launch single VM |
| `05-ssh-vm.sh` | SSH into single VM |
| `run-all.sh` | Run single-VM setup |

## References

- [Cloud Hypervisor GitHub](https://github.com/cloud-hypervisor/cloud-hypervisor)
- [Rust Hypervisor Firmware](https://github.com/cloud-hypervisor/rust-hypervisor-firmware)
- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/)
- [Cloud-init Documentation](https://cloudinit.readthedocs.io/)

## License

MIT
