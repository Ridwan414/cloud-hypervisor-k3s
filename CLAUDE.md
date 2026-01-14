# Cloud Hypervisor VM PoC

A Makefile-based system to launch, manage, and network multiple virtual machines using Cloud Hypervisor (a lightweight, Rust-based VMM).

## Project Purpose

This project explores:
- Running multiple VMs efficiently using Cloud Hypervisor (alternative to KVM/QEMU)
- Networking VMs across bare metal hosts via WireGuard mesh networking
- Solving mesh networking problems (NAT traversal, port forwarding, firewall rules)

## Directory Structure

```
scripts/           # Bash scripts for VM lifecycle management
  01-setup.sh      # Download cloud-hypervisor, firmware, Ubuntu image
  vm-create.sh     # Create VM with disk, cloud-init, networking (sudo)
  vm-start.sh      # Launch cloud-hypervisor process
  vm-stop.sh       # Stop running VM
  vm-delete.sh     # Delete VM and cleanup resources (sudo)
  vm-list.sh       # Show all VMs and their status
  vm-ssh.sh        # SSH convenience wrapper
  cleanup.sh       # Remove all VMs and reset networking (sudo)

docs/              # Documentation
  problem.md       # Root cause analysis of networking issues
  solutions.md     # 5 solutions with trade-offs
  multi-vm-architecture.md  # VM system design
  concepts.md      # Networking concepts (NAT, STUN, WireGuard)

vm/                # Runtime directory (gitignored)
  cloud-hypervisor # Binary
  hypervisor-fw    # UEFI firmware
  *.raw            # Disk images
  vm-<N>/          # Per-VM directories
```

## Common Commands

```bash
make setup              # Download dependencies
make vm-create ID=1     # Create VM 1 (requires sudo)
make vm-start ID=1      # Launch VM 1
make vm-ssh ID=1        # SSH into VM 1
make vm-list            # Show all VMs
make vm-stop ID=1       # Stop VM 1
make vm-delete ID=1     # Delete VM 1 (requires sudo)
make clean              # Reset everything (requires sudo)
```

## VM Addressing Scheme

- IP Address: `192.168.100.(ID+1)`
- TAP Device: `tapID`
- Bridge: `vmbridge` at `192.168.100.1/24`

| ID | IP Address | TAP Device |
|----|------------|------------|
| 1  | 192.168.100.2 | tap1 |
| 2  | 192.168.100.3 | tap2 |

## Default VM Credentials

- Username: `cloud`
- Password: `cloud123`

## Technologies

- **Cloud Hypervisor** - Lightweight VMM (Rust-based)
- **Linux KVM** - Kernel hypervisor module
- **Cloud-init** - VM initialization
- **WireGuard** - Mesh networking protocol
- **Netmaker** - WireGuard mesh orchestration
- **iptables** - Linux firewall and NAT
- **Linux Bridge** - VM network bridging

## Environment Variables

```bash
DISK_SIZE=10G      # VM disk size (default)
CPUS=2             # vCPU count
MEMORY=2048M       # RAM allocation
VM_USER=cloud      # SSH username
VM_PASSWORD=cloud123  # SSH password
```

## Key Concepts

### Network Flow
```
VMs → TAP devices → vmbridge (192.168.100.1/24) → iptables NAT → Host NIC → Internet
```

### VM Lifecycle
1. **Create**: Copy disk, generate cloud-init, setup TAP, configure NAT
2. **Start**: Launch cloud-hypervisor process
3. **Stop**: SIGTERM → wait → SIGKILL
4. **Delete**: Stop, remove TAP, cleanup bridge/iptables, delete directory

## Known Issues

The project documents a mesh networking issue where VMs on different bare metal hosts cannot reach each other via Netmaker due to:
- Port detection failures
- Missing DNAT rules
- FORWARD chain DROP policy

See `docs/problem.md` and `docs/solutions.md` for detailed analysis and solutions.
