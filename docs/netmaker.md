# Netmaker Integration for Multi-Host VM Connectivity

This document provides a step-by-step plan for establishing WireGuard mesh connections between VMs running on multiple bare metal hosts using Netmaker.

## Architecture Overview

```
┌─────────────────────────────────────────┐     ┌─────────────────────────────────────────┐
│           BARE METAL HOST 1             │     │           BARE METAL HOST 2             │
│           (Current Host)                │     │           (Remote Host)                 │
│                                         │     │                                         │
│  ┌─────────────┐    ┌─────────────┐     │     │     ┌─────────────┐    ┌─────────────┐  │
│  │    VM-1     │    │    VM-2     │     │     │     │    VM-3     │    │    VM-4     │  │
│  │192.168.100.2│    │192.168.100.3│     │     │     │192.168.100.2│    │192.168.100.3│  │
│  │             │    │             │     │     │     │             │    │             │  │
│  │ netclient   │    │ netclient   │     │     │     │ netclient   │    │ netclient   │  │
│  │ wg0: 10.x.x │    │ wg0: 10.x.x │     │     │     │ wg0: 10.x.x │    │ wg0: 10.x.x │  │
│  └──────┬──────┘    └──────┬──────┘     │     │     └──────┬──────┘    └──────┬──────┘  │
│         │                  │            │     │            │                  │         │
│         └────────┬─────────┘            │     │            └────────┬─────────┘         │
│                  │                      │     │                     │                   │
│           ┌──────┴──────┐               │     │              ┌──────┴──────┐            │
│           │  vmbridge   │               │     │              │  vmbridge   │            │
│           │192.168.100.1│               │     │              │192.168.100.1│            │
│           └──────┬──────┘               │     │              └──────┬──────┘            │
│                  │                      │     │                     │                   │
│           ┌──────┴──────┐               │     │              ┌──────┴──────┐            │
│           │  Host NIC   │               │     │              │  Host NIC   │            │
│           │ Public/LAN  │               │     │              │ Public/LAN  │            │
│           └──────┬──────┘               │     │              └──────┬──────┘            │
└──────────────────┼──────────────────────┘     └─────────────────────┼───────────────────┘
                   │                                                  │
                   │            ┌─────────────────────┐               │
                   │            │   NETMAKER SERVER   │               │
                   └────────────┤   (Self-Hosted)     ├───────────────┘
                                │                     │
                                │  - Network mgmt    │
                                │  - Key distribution │
                                │  - Peer discovery   │
                                └─────────────────────┘

═══════════════════════════════════════════════════════════════════════════════════════════
                              WIREGUARD MESH NETWORK (10.10.0.0/24)
                                    Managed by Netmaker
═══════════════════════════════════════════════════════════════════════════════════════════
```

## Prerequisites

- [x] Self-hosted Netmaker server (already available)
- [ ] Netmaker dashboard access (admin credentials)
- [ ] Both bare metal hosts have internet connectivity
- [ ] UDP port 51820 (WireGuard) open between hosts (or use Netmaker relay)
- [ ] VMs have internet access (for netclient download)

## Step-by-Step Plan

---

### Phase 1: Netmaker Server Configuration

#### Step 1.1: Create a New Network in Netmaker

1. Log into your Netmaker dashboard
2. Navigate to **Networks** > **Create Network**
3. Configure the network:

| Field | Value | Notes |
|-------|-------|-------|
| **Network Name** | `vm-mesh` | Identifier for your VM network |
| **IPv4 CIDR** | `10.10.0.0/24` | WireGuard overlay subnet (or click **Autofill**) |
| **IPv6 CIDR** | (leave empty) | Not needed for this setup |
| **Default Access Control** | `ALLOW` | All VMs can reach each other by default |

> **Tip**: If unsure about subnets, click the **Autofill** button to auto-generate suitable defaults.

> **Note**: Network settings are immutable after creation. To change settings, you must delete and recreate the network.

4. Click **Create Network**

#### Step 1.2: Generate Enrollment Keys

1. Navigate to **Enrollment Keys** (in sidebar or under Keys)
2. Click **Create** (top right corner)
3. Configure key options:

| Option | Recommendation | Description |
|--------|----------------|-------------|
| **Unlimited Uses** | Yes | Allow multiple VMs to join with same key |
| **Limited Uses** | No | Or set specific number (e.g., 10) |
| **Time-bound** | Optional | Set expiration if needed |
| **Networks** | Select `vm-mesh` | Network(s) nodes will auto-join |

4. Click **Create** and copy the enrollment token

```bash
# Example: The token will look something like this
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...

# Or you may get an enrollment command like:
netclient join -t <token>
```

#### Step 1.3: Note Your Netmaker API Endpoint

You'll need your Netmaker server's API endpoint for netclient:
```bash
# Typically looks like:
api.netmaker.yourdomain.com
# or
netmaker.yourdomain.com/api
```

---

### Phase 2: Prepare VM Images for Netclient

#### Step 2.1: Manual Installation (Testing)

First, test manually on an existing VM:

```bash
# SSH into a running VM
make vm-ssh ID=1

# # Inside VM: Install wireguard
sudo apt install -y wireguard-tools

# Inside VM: Install netclient
curl -sL 'https://apt.netmaker.org/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/netmaker-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/netmaker-keyring.gpg] https://apt.netmaker.org stable main" | sudo tee /etc/apt/sources.list.d/netclient.list
sudo apt update
sudo apt install netclient

# Join the network using enrollment token
sudo netclient join -t <YOUR_ENROLLMENT_TOKEN>

# Verify WireGuard interface
ip addr show nm-vm-mesh
sudo wg show
```

#### Step 2.2: Update Cloud-Init for Automatic Installation

Modify `scripts/vm-create.sh` to include netclient installation in cloud-init:

**File: `scripts/vm-create.sh`**

Add these variables at the top of the script (after line 39):
```bash
# Netmaker configuration (optional)
NETMAKER_TOKEN="${NETMAKER_TOKEN:-}"
NETMAKER_SERVER="${NETMAKER_SERVER:-}"
```

Update the `user-data` cloud-init section to include netclient installation:

```yaml
#cloud-config
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${VM_PASSWORD}
    ssh_authorized_keys:
      - <SSH_KEY>

ssh_pwauth: true
package_update: true
packages:
  - wireguard
  - wireguard-tools

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  # Install netclient if token is provided
  - |
    if [ -n "${NETMAKER_TOKEN}" ]; then
      curl -sL https://raw.githubusercontent.com/gravitl/netmaker/master/scripts/netclient-install.sh | bash
      netclient join -t ${NETMAKER_TOKEN}
    fi
  - echo "VM ${VM_ID} is ready" > /var/log/vm-ready.log
```

---

### Phase 3: Deploy VMs on Bare Metal Host 1 (Current Host)

#### Step 3.1: Create and Start VMs with Netmaker

```bash
# Set Netmaker enrollment token
export NETMAKER_TOKEN="<your-enrollment-token>"

# Create VMs
sudo -E make vm-create ID=1
sudo -E make vm-create ID=2

# Start VMs
make vm-start ID=1 &
make vm-start ID=2 &

# Wait for VMs to boot and join network
sleep 120

# Verify VMs joined Netmaker
make vm-ssh ID=1
# Inside VM:
sudo netclient list
ip addr show nm-vm-mesh
```

#### Step 3.2: Verify in Netmaker Dashboard

1. Go to **Networks** > **vm-mesh** > **Nodes**
2. Verify VM-1 and VM-2 appear in the node list
3. Note their assigned WireGuard IPs (e.g., 10.10.0.2, 10.10.0.3)

---

### Phase 4: Set Up Bare Metal Host 2 (Remote Host)

#### Step 4.1: Clone Repository on Remote Host

```bash
# On Bare Metal Host 2
git clone <your-repo-url> cloud-hypervisor-k3s-poc
cd cloud-hypervisor-k3s-poc

# Run setup
make setup
```

#### Step 4.2: Create and Start VMs on Remote Host

```bash
# Set same Netmaker enrollment token
export NETMAKER_TOKEN="<your-enrollment-token>"

# Create VMs (use different IDs to avoid confusion, though IPs are local)
sudo -E make vm-create ID=1
sudo -E make vm-create ID=2

# Start VMs
make vm-start ID=1 &
make vm-start ID=2 &
```

---

### Phase 5: Verify Cross-Host Connectivity

#### Step 5.1: Check Netmaker Dashboard

1. All 4 VMs should appear in **Networks** > **vm-mesh** > **Nodes**
2. Each should have a unique WireGuard IP in 10.10.0.0/24

Example node list:
| Node Name | Host | WireGuard IP | Status |
|-----------|------|--------------|--------|
| vm-1-host1 | BM1 | 10.10.0.2 | Connected |
| vm-2-host1 | BM1 | 10.10.0.3 | Connected |
| vm-1-host2 | BM2 | 10.10.0.4 | Connected |
| vm-2-host2 | BM2 | 10.10.0.5 | Connected |

#### Step 5.2: Test Connectivity Between VMs

```bash
# From VM-1 on Host 1, ping VM-1 on Host 2
make vm-ssh ID=1
ping 10.10.0.4  # VM on remote host

# Test all peers
sudo wg show nm-vm-mesh
```

#### Step 5.3: Verify WireGuard Tunnel

```bash
# Check WireGuard status
sudo wg show

# Expected output shows peers with handshake timestamps:
# interface: nm-vm-mesh
#   public key: <key>
#   private key: (hidden)
#   listening port: 51820
#
# peer: <peer-public-key>
#   endpoint: <remote-host-ip>:51820
#   allowed ips: 10.10.0.4/32
#   latest handshake: 5 seconds ago
#   transfer: 1.5 KiB received, 2.1 KiB sent
```

---

### Phase 6: Advanced Configuration

#### Step 6.1: Configure Egress Gateway (Optional)

Allow VMs to access each other's local networks:

1. In Netmaker dashboard, select a node
2. Enable **Egress Gateway**
3. Configure egress range: `192.168.100.0/24`
4. This allows VMs to reach each other's local bridge network

#### Step 6.2: Set Up Relay Node (If NAT Traversal Fails)

If VMs can't establish direct connections:

1. Choose a VM with best connectivity as relay
2. In Netmaker: **Nodes** > Select node > **Set as Relay**
3. Select which nodes should use this relay

#### Step 6.3: DNS Configuration (Optional)

Enable Netmaker DNS for service discovery:

```bash
# On each VM, add to /etc/resolv.conf or netplan
nameserver <netmaker-dns-ip>
search vm-mesh.netmaker
```

---

## Code Changes Summary

### Files to Modify

#### 1. `scripts/vm-create.sh`

Add Netmaker token support:

```diff
+ # Netmaker configuration (optional)
+ NETMAKER_TOKEN="${NETMAKER_TOKEN:-}"

# In user-data section, add:
+ packages:
+   - wireguard
+   - wireguard-tools
+
  runcmd:
    - systemctl enable ssh
    - systemctl start ssh
+   - |
+     if [ -n "${NETMAKER_TOKEN}" ]; then
+       curl -sL https://raw.githubusercontent.com/gravitl/netmaker/master/scripts/netclient-install.sh | bash
+       netclient join -t ${NETMAKER_TOKEN}
+     fi
    - echo "VM ${VM_ID} is ready" > /var/log/vm-ready.log
```

#### 2. `Makefile`

Add documentation for Netmaker:

```diff
+ # Netmaker Integration (optional)
+ # Set NETMAKER_TOKEN environment variable to auto-join VMs to mesh network
+ # Example: NETMAKER_TOKEN=eyJ... make vm-create ID=1
```

#### 3. New Script: `scripts/vm-netmaker-join.sh` (Optional)

For manually joining existing VMs:

```bash
#!/bin/bash
# Join an existing VM to Netmaker network
# Usage: vm-netmaker-join.sh <VM_ID> <NETMAKER_TOKEN>

VM_ID="$1"
TOKEN="$2"

if [[ -z "$VM_ID" ]] || [[ -z "$TOKEN" ]]; then
    echo "Usage: $0 <VM_ID> <NETMAKER_TOKEN>"
    exit 1
fi

source "$(dirname "$0")/../vm/vm-${VM_ID}/vm.conf"

ssh "${VM_USER}@${VM_IP}" << EOF
curl -sL https://raw.githubusercontent.com/gravitl/netmaker/master/scripts/netclient-install.sh | sudo bash
sudo netclient join -t ${TOKEN}
EOF
```

---

## Troubleshooting

### Issue: VM Can't Reach Netmaker Server

```bash
# Check DNS resolution
nslookup <netmaker-domain>

# Check connectivity
curl -v https://<netmaker-api-endpoint>/api/health
```

### Issue: WireGuard Handshake Fails

```bash
# Check if UDP 51820 is open
sudo netstat -ulnp | grep 51820

# Test UDP connectivity from host
nc -u -v <remote-host-ip> 51820
```

### Issue: Peers Connected but No Traffic

```bash
# Check routing table
ip route | grep nm-vm-mesh

# Check iptables isn't blocking
sudo iptables -L -n | grep -i drop
```

### Issue: Netclient Won't Start

```bash
# Check service status
sudo systemctl status netclient

# View logs
sudo journalctl -u netclient -f

# Restart service
sudo systemctl restart netclient
```

---

## Network Topology Summary

| Host | VM ID | Local IP | WireGuard IP | Hostname |
|------|-------|----------|--------------|----------|
| BM1 | 1 | 192.168.100.2 | 10.10.0.X | vm-1-bm1 |
| BM1 | 2 | 192.168.100.3 | 10.10.0.X | vm-2-bm1 |
| BM2 | 1 | 192.168.100.2 | 10.10.0.X | vm-1-bm2 |
| BM2 | 2 | 192.168.100.3 | 10.10.0.X | vm-2-bm2 |

**Note**: Local IPs (192.168.100.x) are only reachable within each host. WireGuard IPs (10.10.0.x) provide cross-host connectivity.

---

## Next Steps

1. [ ] Create network in Netmaker dashboard
2. [ ] Generate enrollment token
3. [ ] Test manual netclient installation on one VM
4. [ ] Update vm-create.sh with Netmaker support
5. [ ] Deploy VMs on both bare metal hosts
6. [ ] Verify cross-host connectivity
7. [ ] Configure egress gateways if needed
8. [ ] Set up relay node if NAT traversal fails
