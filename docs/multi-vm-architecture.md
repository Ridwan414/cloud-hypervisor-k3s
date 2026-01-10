# Multi-VM Architecture

This document explains how the multi-VM system works, including networking, resource isolation, and the lifecycle of VMs.

## Overview

The multi-VM system allows running multiple Cloud Hypervisor VMs simultaneously on a single host. Each VM is isolated with its own:
- Disk image (copy-on-write from base)
- Cloud-init configuration
- TAP network device
- Unique IP and MAC address

All VMs share a common bridge network (`vmbridge`) that provides connectivity between VMs and to the internet via NAT.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              HOST SYSTEM                                     │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                        /dev/kvm (KVM Module)                          │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│         │                        │                        │                  │
│         ▼                        ▼                        ▼                  │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐        │
│  │ cloud-hypervisor│     │ cloud-hypervisor│     │ cloud-hypervisor│        │
│  │    Process 1    │     │    Process 2    │     │    Process 3    │        │
│  │                 │     │                 │     │                 │        │
│  │  ┌───────────┐  │     │  ┌───────────┐  │     │  ┌───────────┐  │        │
│  │  │   VM 1    │  │     │  │   VM 2    │  │     │  │   VM 3    │  │        │
│  │  │  2 vCPUs  │  │     │  │  2 vCPUs  │  │     │  │  2 vCPUs  │  │        │
│  │  │  2GB RAM  │  │     │  │  2GB RAM  │  │     │  │  2GB RAM  │  │        │
│  │  └───────────┘  │     │  └───────────┘  │     │  └───────────┘  │        │
│  └────────┬────────┘     └────────┬────────┘     └────────┬────────┘        │
│           │                       │                       │                  │
│   ┌───────┴───────┐       ┌───────┴───────┐       ┌───────┴───────┐         │
│   │   vm-1/       │       │   vm-2/       │       │   vm-3/       │         │
│   │  disk.raw     │       │  disk.raw     │       │  disk.raw     │         │
│   │  cloudinit.img│       │  cloudinit.img│       │  cloudinit.img│         │
│   └───────────────┘       └───────────────┘       └───────────────┘         │
│                                                                              │
│  ═══════════════════════════ NETWORKING ═══════════════════════════════════ │
│                                                                              │
│   ┌─────────┐             ┌─────────┐             ┌─────────┐               │
│   │  tap1   │             │  tap2   │             │  tap3   │               │
│   │(virtio) │             │(virtio) │             │(virtio) │               │
│   └────┬────┘             └────┬────┘             └────┬────┘               │
│        │                       │                       │                     │
│        └───────────────────────┼───────────────────────┘                     │
│                                │                                             │
│                    ┌───────────┴───────────┐                                 │
│                    │       vmbridge        │                                 │
│                    │    192.168.100.1/24   │                                 │
│                    │    (Linux Bridge)     │                                 │
│                    └───────────┬───────────┘                                 │
│                                │                                             │
│                    ┌───────────┴───────────┐                                 │
│                    │      iptables NAT     │                                 │
│                    │     MASQUERADE        │                                 │
│                    └───────────┬───────────┘                                 │
│                                │                                             │
│                    ┌───────────┴───────────┐                                 │
│                    │    Primary NIC        │                                 │
│                    │   (e.g., eth0/eno1)   │                                 │
│                    └───────────┬───────────┘                                 │
└────────────────────────────────┼─────────────────────────────────────────────┘
                                 │
                            Internet
```

## Components

### 1. Cloud Hypervisor Process

Each VM runs as a separate `cloud-hypervisor` process. Cloud Hypervisor is a lightweight VMM (Virtual Machine Monitor) written in Rust that:
- Uses KVM for hardware virtualization
- Provides virtio devices for disk, network, and console
- Boots VMs using UEFI firmware or direct kernel boot

```bash
# Example cloud-hypervisor command for VM 1
./cloud-hypervisor \
    --firmware ./hypervisor-fw \
    --disk path=vm-1/disk.raw path=vm-1/cloudinit.img \
    --cpus boot=2 \
    --memory size=2048M \
    --net tap=tap1,mac=12:34:56:78:9a:01
```

### 2. VM Directory Structure

Each VM has its own directory under `vm/`:

```
vm/
├── cloud-hypervisor          # Shared binary
├── hypervisor-fw             # Shared UEFI firmware
├── jammy-server-cloudimg-amd64.raw  # Base Ubuntu image (shared)
│
├── vm-1/                     # VM 1 specific files
│   ├── disk.raw              # Copy of base image (sparse)
│   ├── cloudinit.img         # Cloud-init ISO
│   ├── meta-data             # Cloud-init metadata
│   ├── user-data             # Cloud-init user config
│   ├── network-config        # Cloud-init network config
│   ├── vm.conf               # VM configuration (IP, MAC, etc.)
│   └── vm.pid                # PID file (when running)
│
└── vm-2/                     # VM 2 specific files
    └── ...
```

### 3. Bridge Networking

All VMs connect to a shared Linux bridge (`vmbridge`):

```
                    ┌─────────────────────────────┐
                    │         vmbridge            │
                    │      192.168.100.1/24       │
                    └──────┬──────┬──────┬────────┘
                           │      │      │
                    ┌──────┘      │      └──────┐
                    │             │             │
               ┌────┴────┐  ┌────┴────┐  ┌────┴────┐
               │  tap1   │  │  tap2   │  │  tap3   │
               └────┬────┘  └────┬────┘  └────┬────┘
                    │             │             │
               ┌────┴────┐  ┌────┴────┐  ┌────┴────┐
               │  VM 1   │  │  VM 2   │  │  VM 3   │
               │  .2     │  │  .3     │  │  .4     │
               └─────────┘  └─────────┘  └─────────┘
```

**Why a bridge instead of individual TAPs?**
- Multiple TAP devices can't share the same IP address
- A bridge acts as a virtual switch connecting all TAPs
- VMs can communicate with each other through the bridge
- Single gateway IP (192.168.100.1) for all VMs

### 4. NAT and IP Forwarding

Internet access is provided via NAT:

```bash
# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# NAT masquerade rule
iptables -t nat -A POSTROUTING -o <primary-nic> -j MASQUERADE

# Forward rules for bridge
iptables -A FORWARD -i vmbridge -o <primary-nic> -j ACCEPT
iptables -A FORWARD -i <primary-nic> -o vmbridge -m state --state RELATED,ESTABLISHED -j ACCEPT
```

## VM Lifecycle

### Creation (`make vm-create ID=N`)

1. **Validate** - Check VM ID is valid and doesn't exist
2. **Create directory** - `vm/vm-N/`
3. **Copy disk** - Sparse copy of base image to `vm-N/disk.raw`
4. **Generate cloud-init** - Create meta-data, user-data, network-config, and ISO
5. **Setup bridge** - Create `vmbridge` if not exists (first VM only)
6. **Setup TAP** - Create `tapN` and add to bridge
7. **Configure NAT** - Add iptables rules if not exists
8. **Save config** - Write `vm.conf` with VM parameters

### Starting (`make vm-start ID=N`)

1. **Load config** - Read `vm-N/vm.conf`
2. **Validate** - Check VM not already running
3. **Set capabilities** - `cap_net_admin` for TAP access
4. **Launch** - Start cloud-hypervisor with VM-specific parameters
5. **Save PID** - Write process ID to `vm.pid`

### Stopping (`make vm-stop ID=N`)

1. **Read PID** - Get process ID from `vm.pid`
2. **Signal** - Send SIGTERM for graceful shutdown
3. **Wait** - Allow up to 5 seconds for shutdown
4. **Force kill** - SIGKILL if still running
5. **Cleanup** - Remove PID file

### Deletion (`make vm-delete ID=N`)

1. **Stop VM** - If running
2. **Remove directory** - Delete `vm/vm-N/`
3. **Remove TAP** - Delete `tapN` from bridge
4. **Cleanup bridge** - Remove `vmbridge` if no VMs remain
5. **Cleanup iptables** - Remove NAT rules if no VMs remain

## Resource Allocation

### Per-VM Resources

| Resource | Default | Configurable |
|----------|---------|--------------|
| vCPUs | 2 | `CPUS=N` |
| Memory | 2048M | `MEMORY=NM` |
| Disk | ~2.2GB | Fixed (base image size) |
| Network | 1 virtio-net | Fixed |

### Addressing Formula

Given VM ID `N`:
- **IP Address**: `192.168.100.(N+1)`
- **TAP Device**: `tapN`
- **MAC Address**: `12:34:56:78:9a:XX` where XX is N in hex

Examples:
| ID | IP | TAP | MAC |
|----|-----|-----|-----|
| 1 | 192.168.100.2 | tap1 | 12:34:56:78:9a:01 |
| 2 | 192.168.100.3 | tap2 | 12:34:56:78:9a:02 |
| 10 | 192.168.100.11 | tap10 | 12:34:56:78:9a:0a |
| 255 | 192.168.100.256 | tap255 | 12:34:56:78:9a:ff |

**Note**: Maximum practical VMs is ~253 due to /24 subnet size.

## Cloud-Init Configuration

Each VM is configured at first boot via cloud-init:

### meta-data
```yaml
instance-id: vm-1
local-hostname: vm-1
```

### user-data
```yaml
#cloud-config
users:
  - name: cloud
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: cloud123
    ssh_authorized_keys:
      - <host SSH public key if available>

ssh_pwauth: true
package_update: false

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
```

### network-config
```yaml
version: 2
ethernets:
  eth0:
    match:
      driver: virtio_net
    dhcp4: false
    addresses:
      - 192.168.100.2/24
    routes:
      - to: default
        via: 192.168.100.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
```

## VM Communication

### Host to VM
```bash
ssh cloud@192.168.100.2    # VM 1
ssh cloud@192.168.100.3    # VM 2
```

### VM to VM
```bash
# From VM 1, ping VM 2
ping 192.168.100.3
```

### VM to Internet
```bash
# From any VM
curl https://example.com
```

## Troubleshooting

### Check Bridge Status
```bash
# Show bridge and members
bridge link show
ip addr show vmbridge
```

### Check TAP Devices
```bash
# List all TAP devices
ip link show type tun
```

### Check iptables Rules
```bash
# NAT rules
iptables -t nat -L -n

# Forward rules
iptables -L FORWARD -n
```

### Check VM Processes
```bash
# List cloud-hypervisor processes
ps aux | grep cloud-hypervisor

# Check specific VM
cat vm/vm-1/vm.pid
```

### Network Debugging
```bash
# From host, check connectivity to VM
ping 192.168.100.2

# Check ARP table
arp -n

# Capture traffic on bridge
tcpdump -i vmbridge
```

## Limitations

1. **Subnet size**: Maximum ~253 VMs with /24 subnet
2. **Disk space**: Each VM uses ~2.2GB (sparse, grows with usage)
3. **Memory**: Each VM reserves its full memory allocation
4. **No live migration**: VMs must be stopped to move
5. **No snapshots**: Disk changes are permanent

## Security Considerations

1. **Default credentials**: Change `cloud123` password in production
2. **Network isolation**: All VMs share the same L2 network
3. **Root access**: `vm-create` and `vm-delete` require sudo
4. **No encryption**: Disk images are unencrypted
