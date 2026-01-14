# VM Mesh Networking Solutions

This document provides detailed solutions for establishing WireGuard mesh connectivity between VMs running on different bare metal hosts.

## Problem Summary

VMs on different bare metal hosts cannot communicate over the Netmaker mesh because:
1. **Wrong endpoint ports** - Netmaker detected port 51821 instead of actual WireGuard ports
2. **No DNAT rules** - Bare metal has no rules to forward incoming UDP to VMs
3. **Firewall blocks new connections** - FORWARD chain drops new incoming UDP packets

See [problem.md](problem.md) for detailed analysis.

---

## Solution Comparison

| Solution | Complexity | Performance | Reliability | Best For |
|----------|------------|-------------|-------------|----------|
| 1. Netmaker Relay | Very Low | Medium | High | Quick fix, testing |
| 2. Static Port Forward | Low | High | Medium | Single VM, testing |
| 3. Dynamic Port Forward | Medium | High | High | Production, multiple VMs |
| 4. Bare Metal Mesh | Medium | Highest | Highest | Large scale, many VMs |
| 5. Replace with ikto | Medium | High | High | Full control needed |

---

## Solution 1: Netmaker Relay Mode

### How It Works

Instead of VMs connecting directly to each other (P2P), traffic is routed through the Netmaker server which acts as a relay/proxy.

```
                          WITHOUT RELAY (Current - Broken)
┌─────────────┐                                           ┌─────────────┐
│   VM-34     │─────────── Direct P2P (BLOCKED) ─────────▶│   VM-23     │
│ 100.123.183.2│                    ✗                      │ 100.123.183.3│
└─────────────┘                                           └─────────────┘


                          WITH RELAY (Working)
┌─────────────┐         ┌─────────────────┐         ┌─────────────┐
│   VM-34     │────────▶│ NETMAKER SERVER │────────▶│   VM-23     │
│ 100.123.183.2│   ✓     │  100.123.183.1  │    ✓    │ 100.123.183.3│
└─────────────┘         │    (RELAY)      │         └─────────────┘
                        └─────────────────┘
```

### Why It Works

- Both VMs can already reach the Netmaker server (verified by successful handshakes)
- The server has a public IP and properly configured firewall
- Traffic flows: VM-34 → Server → VM-23 (both directions work)

### Implementation Steps

#### Option A: Via Netmaker Dashboard (Recommended)

1. Log into your Netmaker dashboard
2. Navigate to **Networks** → **vm-mesh**
3. Go to **Nodes** tab
4. Find the Netmaker server node (usually shows as the server hostname)
5. Click on the node to edit
6. Enable **"Relay"** or **"Hub"** functionality
7. Select which nodes should use this relay (select VM-34 and VM-23)
8. Save changes

#### Option B: Via Netmaker API/CLI

```bash
# If you have nmctl installed
nmctl node update <server-node-id> --relay=true --network=vm-mesh

# Or via API
curl -X PUT "https://api.your-netmaker.com/api/nodes/vm-mesh/<node-id>" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"isrelay": true}'
```

#### Option C: Force Relay on Client Side

On each VM, you can force traffic through the server:

```bash
# Check current configuration
sudo netclient list

# Pull latest configuration (may auto-enable relay if configured on server)
sudo netclient pull

# Restart netclient to apply changes
sudo systemctl restart netclient
```

### Verify It's Working

```bash
# On VM-34
ping 100.123.183.3

# Check WireGuard - traffic should flow through server
sudo wg show
# Look for: transfer showing bytes received (not 0)
```

### Pros and Cons

| Pros | Cons |
|------|------|
| No changes to bare metal firewall | Higher latency (extra hop) |
| No code changes needed | Server becomes single point of failure |
| Works immediately | Server bandwidth becomes bottleneck |
| Handles any NAT situation | Not true P2P |

### When to Use

- Quick fix while implementing a better solution
- Testing and development environments
- When direct P2P is impossible (symmetric NAT, strict firewalls)

---

## Solution 2: Static Port Forwarding (Manual)

### How It Works

Manually add iptables rules on each bare metal host to:
1. **DNAT** - Redirect incoming UDP traffic to the VM
2. **FORWARD** - Allow the forwarded traffic through the firewall

```
                    BEFORE (Broken)

Internet ──▶ BM:51822 ──▶ [DROPPED by firewall]
                         No DNAT rule
                         FORWARD policy DROP


                    AFTER (Working)

Internet ──▶ BM:51822 ──▶ [DNAT to 192.168.200.35:51822]
                              │
                              ▼
                         [FORWARD ACCEPT]
                              │
                              ▼
                         VM:51822 ✓
```

### Implementation Steps

#### Step 1: Add Rules on Bare Metal 1 (bm-94-139)

```bash
# Variables
VM_IP="192.168.200.35"
WG_PORT="51822"
EXT_IF="eno1"  # External interface (check with: ip route | grep default)

# 1. Add FORWARD rule to allow UDP to VM's WireGuard port
sudo iptables -I FORWARD -p udp -d ${VM_IP} --dport ${WG_PORT} -j ACCEPT

# 2. Add DNAT rule to redirect incoming UDP to VM
sudo iptables -t nat -A PREROUTING -i ${EXT_IF} -p udp --dport ${WG_PORT} \
  -j DNAT --to-destination ${VM_IP}:${WG_PORT}

# 3. Verify rules were added
sudo iptables -L FORWARD -n -v | grep ${WG_PORT}
sudo iptables -t nat -L PREROUTING -n -v | grep ${WG_PORT}
```

#### Step 2: Add Rules on Bare Metal 2

```bash
# Variables (adjust for your setup)
VM_IP="192.168.100.24"
WG_PORT="51824"
EXT_IF="eno1"  # Or whatever your external interface is

# 1. Add FORWARD rule
sudo iptables -I FORWARD -p udp -d ${VM_IP} --dport ${WG_PORT} -j ACCEPT

# 2. Add DNAT rule
sudo iptables -t nat -A PREROUTING -i ${EXT_IF} -p udp --dport ${WG_PORT} \
  -j DNAT --to-destination ${VM_IP}:${WG_PORT}

# 3. Verify
sudo iptables -L FORWARD -n -v | grep ${WG_PORT}
sudo iptables -t nat -L PREROUTING -n -v | grep ${WG_PORT}
```

#### Step 3: Fix WireGuard Endpoint Ports

The endpoints are wrong (51821 instead of actual ports). Fix them:

```bash
# On VM-34: Update endpoint for VM-23
sudo wg set netmaker peer COd63R1j6ibFCmBXJJxlPf7+3aC60YKXbaCtjXMthBQ= \
  endpoint 51.38.54.39:51824

# On VM-23: Update endpoint for VM-34
sudo wg set netmaker peer JqcqIheNKSq0CqmagWlfTmepDwpc3ab+1xdf/MpJ1R0= \
  endpoint 54.38.94.139:51822
```

#### Step 4: Test Connectivity

```bash
# From VM-34
ping 100.123.183.3

# From VM-23
ping 100.123.183.2

# Check WireGuard handshake
sudo wg show
# Should see: latest handshake: X seconds ago
# Should see: transfer: X received, Y sent (both non-zero)
```

#### Step 5: Make Rules Persistent (Optional)

```bash
# Install iptables-persistent
sudo apt-get install iptables-persistent

# Save current rules
sudo netfilter-persistent save

# Rules will now survive reboot
```

### How to Remove Rules (Cleanup)

```bash
# Remove FORWARD rule
sudo iptables -D FORWARD -p udp -d ${VM_IP} --dport ${WG_PORT} -j ACCEPT

# Remove DNAT rule
sudo iptables -t nat -D PREROUTING -i ${EXT_IF} -p udp --dport ${WG_PORT} \
  -j DNAT --to-destination ${VM_IP}:${WG_PORT}
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Direct P2P (best performance) | Manual process for each VM |
| No relay overhead | Rules don't survive reboot (without persistence) |
| Simple to understand | Must track ports manually |
| No code changes | Doesn't scale well |

### When to Use

- Single VM or small number of VMs
- Testing the fix before implementing automation
- Understanding the problem before automating

---

## Solution 3: Dynamic Port Forwarding (Automated)

### How It Works

Integrate port forwarding into the VM lifecycle scripts so that:
- **On VM create**: Allocate a WireGuard port and add iptables rules
- **On VM delete**: Remove the iptables rules

Port allocation formula: `WG_PORT = 51820 + VM_ID`

```
VM Creation Flow:

  make vm-create ID=34
         │
         ▼
  ┌─────────────────────┐
  │  Allocate WG Port   │
  │  51820 + 34 = 51854 │
  └──────────┬──────────┘
             │
             ▼
  ┌─────────────────────────────────────────────┐
  │  Add iptables rules:                        │
  │  1. FORWARD -p udp -d VM_IP --dport 51854   │
  │  2. DNAT --to-destination VM_IP:51854       │
  └──────────┬──────────────────────────────────┘
             │
             ▼
  ┌─────────────────────┐
  │  Save WG_PORT to    │
  │  vm.conf            │
  └──────────┬──────────┘
             │
             ▼
  ┌─────────────────────┐
  │  VM starts with     │
  │  cloud-init that    │
  │  configures netclient│
  │  to use port 51854  │
  └─────────────────────┘
```

### Implementation Steps

#### Step 1: Modify `scripts/vm-create.sh`

Add the following after line 41 (after `DISK_SIZE` variable):

```bash
# WireGuard port allocation for mesh networking
# Each VM gets a unique port: 51820 + VM_ID
WG_PORT=$((51820 + VM_ID))
```

Add the following after line 207 (after existing iptables rules, before saving vm.conf):

```bash
# ═══════════════════════════════════════════════════════════════════════════════
# WireGuard Port Forwarding for Mesh Networking
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Setting up WireGuard port forwarding..."
echo "  Allocated port: UDP ${WG_PORT}"
echo "  Forwarding: ${PRIMARY_IF}:${WG_PORT} → ${VM_IP}:${WG_PORT}"

# Allow forwarding UDP traffic to VM's WireGuard port
if ! iptables -C FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT
    echo "  Added FORWARD rule for UDP ${WG_PORT}"
fi

# DNAT: Redirect incoming UDP on WG_PORT to VM
if ! iptables -t nat -C PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}" 2>/dev/null; then
    iptables -t nat -A PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}"
    echo "  Added DNAT rule: ${PRIMARY_IF}:${WG_PORT} → ${VM_IP}:${WG_PORT}"
fi
```

Modify the vm.conf section (around line 210) to include WG_PORT:

```bash
# Save VM metadata
cat > "${VM_DIR}/vm.conf" <<EOF
VM_ID=${VM_ID}
VM_IP=${VM_IP}
TAP_DEV=${TAP_DEV}
MAC_ADDR=${MAC_ADDR}
VM_HOSTNAME=${VM_HOSTNAME}
VM_USER=${VM_USER}
WG_PORT=${WG_PORT}
EOF
```

Update the cloud-init user-data section to configure netclient with the allocated port:

```bash
# In the runcmd section, update the netclient join command:
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - |
    if [ -n "${NETMAKER_TOKEN}" ]; then
      curl -sL https://raw.githubusercontent.com/gravitl/netmaker/master/scripts/netclient-install.sh | bash
      # Join with specific port
      netclient join -t ${NETMAKER_TOKEN} --port ${WG_PORT}
    fi
  - echo "VM ${VM_ID} is ready" > /var/log/vm-ready.log
```

#### Step 2: Modify `scripts/vm-delete.sh`

Add the following before line 52 (before removing VM directory):

```bash
# ═══════════════════════════════════════════════════════════════════════════════
# Clean up WireGuard Port Forwarding Rules
# ═══════════════════════════════════════════════════════════════════════════════
if [[ -f "${VM_DIR}/vm.conf" ]]; then
    source "${VM_DIR}/vm.conf"

    if [[ -n "${WG_PORT}" ]] && [[ -n "${VM_IP}" ]]; then
        echo "Removing WireGuard port forwarding rules..."

        # Get primary interface
        PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)

        # Remove FORWARD rule
        if iptables -C FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null; then
            iptables -D FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT
            echo "  Removed FORWARD rule for UDP ${WG_PORT}"
        fi

        # Remove DNAT rule
        if iptables -t nat -C PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}" 2>/dev/null; then
            iptables -t nat -D PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}"
            echo "  Removed DNAT rule for UDP ${WG_PORT}"
        fi
    fi
fi
```

#### Step 3: Create Helper Script (Optional)

Create `scripts/vm-wg-status.sh` to check WireGuard port forwarding status:

```bash
#!/bin/bash
# Show WireGuard port forwarding status for all VMs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"

echo "=== WireGuard Port Forwarding Status ==="
echo ""

printf "%-8s %-18s %-10s %-15s %-10s\n" "VM_ID" "VM_IP" "WG_PORT" "FORWARD" "DNAT"
printf "%-8s %-18s %-10s %-15s %-10s\n" "------" "-----------------" "--------" "--------------" "--------"

for vm_dir in "${VM_BASE_DIR}"/vm-*/; do
    if [[ -f "${vm_dir}/vm.conf" ]]; then
        source "${vm_dir}/vm.conf"

        # Check FORWARD rule
        if sudo iptables -C FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null; then
            FWD_STATUS="✓ OK"
        else
            FWD_STATUS="✗ Missing"
        fi

        # Check DNAT rule
        PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
        if sudo iptables -t nat -C PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}" 2>/dev/null; then
            DNAT_STATUS="✓ OK"
        else
            DNAT_STATUS="✗ Missing"
        fi

        printf "%-8s %-18s %-10s %-15s %-10s\n" "${VM_ID}" "${VM_IP}" "${WG_PORT}" "${FWD_STATUS}" "${DNAT_STATUS}"
    fi
done
```

#### Step 4: Update Makefile

Add new target for checking WireGuard status:

```makefile
vm-wg-status:
	@sudo ./scripts/vm-wg-status.sh
```

### Complete Modified Files

Here's what the key sections look like after modification:

**vm-create.sh (key additions):**
```bash
#!/bin/bash
# ... existing code ...

VM_ID="$1"

# WireGuard port allocation (ADD THIS AFTER VM_ID VALIDATION)
WG_PORT=$((51820 + VM_ID))

# ... existing code for creating VM ...

# After existing iptables rules (~line 207), ADD:
echo ""
echo "Setting up WireGuard port forwarding..."
echo "  Allocated port: UDP ${WG_PORT}"

if ! iptables -C FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT
fi

if ! iptables -t nat -C PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}" 2>/dev/null; then
    iptables -t nat -A PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}"
fi

# UPDATE vm.conf to include WG_PORT:
cat > "${VM_DIR}/vm.conf" <<EOF
VM_ID=${VM_ID}
VM_IP=${VM_IP}
TAP_DEV=${TAP_DEV}
MAC_ADDR=${MAC_ADDR}
VM_HOSTNAME=${VM_HOSTNAME}
VM_USER=${VM_USER}
WG_PORT=${WG_PORT}
EOF

echo ""
echo "=== VM ${VM_ID} Created Successfully ==="
echo "WireGuard port: ${WG_PORT}"
echo ""
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Fully automated | Requires script modifications |
| Scales to many VMs | Port must match in netclient config |
| Rules cleaned up on VM delete | Initial implementation effort |
| Direct P2P performance | Must deploy to all bare metal hosts |
| Self-documenting (port in vm.conf) | |

### When to Use

- Production environments
- Multiple VMs per host
- Need reliable, automated solution
- Want direct P2P performance

---

## Solution 4: Bare Metal Mesh (ikto/Ravel Pattern)

### How It Works

Instead of running WireGuard inside VMs, run the mesh agent on the **bare metal hosts**. VMs route their traffic through the host's mesh interface.

```
                    CURRENT APPROACH (Mesh in VMs)

┌─────────────────────────┐         ┌─────────────────────────┐
│    Bare Metal 1         │         │    Bare Metal 2         │
│                         │         │                         │
│  ┌─────────┐ ┌───────┐  │         │  ┌───────┐ ┌─────────┐  │
│  │  VM-1   │ │ VM-2  │  │         │  │ VM-3  │ │  VM-4   │  │
│  │ ┌─────┐ │ │┌─────┐│  │         │  │┌─────┐│ │ ┌─────┐ │  │
│  │ │ WG  │ │ ││ WG  ││  │   NAT   │  ││ WG  ││ │ │ WG  │ │  │
│  │ │mesh │◀┼─┼┼─────┼┼──┼─problems┼──┼┼─────┼┼─┼▶│mesh │ │  │
│  │ └─────┘ │ │└─────┘│  │         │  │└─────┘│ │ └─────┘ │  │
│  └─────────┘ └───────┘  │         │  └───────┘ └─────────┘  │
└─────────────────────────┘         └─────────────────────────┘


                    BARE METAL MESH (Recommended for scale)

┌─────────────────────────┐         ┌─────────────────────────┐
│    Bare Metal 1         │         │    Bare Metal 2         │
│    10.10.0.1 (mesh)     │         │    10.10.0.2 (mesh)     │
│                         │         │                         │
│  ┌─────────┐ ┌───────┐  │         │  ┌───────┐ ┌─────────┐  │
│  │  VM-1   │ │ VM-2  │  │         │  │ VM-3  │ │  VM-4   │  │
│  │ 192.168.│ │192.168│  │         │  │192.168│ │ 192.168.│  │
│  │ 100.2   │ │100.3  │  │         │  │100.2  │ │ 100.3   │  │
│  └────┬────┘ └───┬───┘  │         │  └───┬───┘ └────┬────┘  │
│       └─────┬────┘      │         │      └─────┬────┘       │
│             │           │         │            │            │
│       ┌─────▼─────┐     │         │      ┌─────▼─────┐      │
│       │ vmbridge  │     │         │      │ vmbridge  │      │
│       │192.168.100.1    │         │      │192.168.100.1     │
│       └─────┬─────┘     │         │      └─────┬─────┘      │
│             │           │         │            │            │
│       ┌─────▼─────┐     │  Direct │      ┌─────▼─────┐      │
│       │  WG Mesh  │◀────┼────P2P──┼─────▶│  WG Mesh  │      │
│       │ 10.10.0.1 │     │    ✓    │      │ 10.10.0.2 │      │
│       └───────────┘     │         │      └───────────┘      │
└─────────────────────────┘         └─────────────────────────┘

VM-1 on BM1 reaches VM-3 on BM2:
  192.168.100.2 → vmbridge → WG tunnel → vmbridge → 192.168.100.2
  (routed via 10.10.0.1)      ↓↑       (routed via 10.10.0.2)
                          10.10.0.1 ←→ 10.10.0.2
```

### Why It Works Better

1. **No NAT issues** - Bare metal has public IP, WireGuard binds directly
2. **Single WireGuard instance per host** - Simpler to manage
3. **VMs don't need WireGuard** - Lighter VMs, simpler networking
4. **Scales better** - Add VMs without adding mesh nodes

### Implementation Steps

#### Step 1: Install Mesh Agent on Bare Metal Hosts

**Option A: Using Netmaker**
```bash
# On each bare metal host
curl -sL https://raw.githubusercontent.com/gravitl/netmaker/master/scripts/netclient-install.sh | bash
sudo netclient join -t <YOUR_ENROLLMENT_TOKEN>
```

**Option B: Using ikto**
```bash
# Install ikto
wget https://github.com/valyentdev/ikto/releases/latest/download/ikto_linux_amd64
chmod +x ikto_linux_amd64
sudo mv ikto_linux_amd64 /usr/local/bin/ikto

# Generate config
ikto init > /etc/ikto/config.json

# Edit config with your settings
# - Set advertise_address to bare metal's public IP
# - Set private_address to mesh IP
# - Configure NATS connection

# Start agent
ikto agent -c /etc/ikto/config.json
```

#### Step 2: Configure Routing on Bare Metal

Each bare metal needs to know how to route traffic to remote VMs:

```bash
# On Bare Metal 1: Route to BM2's VM subnet via mesh
# Assuming BM2's mesh IP is 10.10.0.2 and uses same VM subnet
ip route add 192.168.100.0/24 via 10.10.0.2 dev wg-mesh

# If each BM uses different VM subnets:
# BM1 VMs: 192.168.100.0/24
# BM2 VMs: 192.168.200.0/24
ip route add 192.168.200.0/24 via 10.10.0.2 dev wg-mesh
```

#### Step 3: Configure VM Default Gateway

VMs should route mesh traffic through the bare metal:

```bash
# Option A: Add specific route in VM for mesh network
ip route add 10.10.0.0/16 via 192.168.100.1

# Option B: Add route for remote VM subnets
ip route add 192.168.200.0/24 via 192.168.100.1
```

Or configure in cloud-init network-config:
```yaml
version: 2
ethernets:
  eth0:
    addresses:
      - 192.168.100.2/24
    routes:
      - to: default
        via: 192.168.100.1
      - to: 192.168.200.0/24  # Remote VM subnet
        via: 192.168.100.1
      - to: 10.10.0.0/16      # Mesh network
        via: 192.168.100.1
```

#### Step 4: Enable IP Forwarding on Bare Metal

```bash
# Already done in vm-create.sh, but verify:
sysctl net.ipv4.ip_forward
# Should show: net.ipv4.ip_forward = 1
```

### Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                              BARE METAL 1                                       │
│                          Public IP: 54.38.94.139                               │
│                                                                                │
│   ┌──────────────────────────────────────────────────────────────────────┐    │
│   │                         Mesh Agent (ikto/netclient)                   │    │
│   │                                                                       │    │
│   │   Interface: wg-mesh                                                  │    │
│   │   Mesh IP: 10.10.0.1/16                                               │    │
│   │   Listen Port: UDP 51820                                              │    │
│   │   Public Endpoint: 54.38.94.139:51820                                 │    │
│   └───────────────────────────────┬──────────────────────────────────────┘    │
│                                   │                                            │
│   Routes:                         │                                            │
│   • 10.10.0.0/16 dev wg-mesh     │                                            │
│   • 192.168.200.0/24 via 10.10.0.2  (remote VMs)                              │
│                                   │                                            │
│   ┌───────────────────────────────▼──────────────────────────────────────┐    │
│   │                           vmbridge                                    │    │
│   │                        192.168.100.1/24                               │    │
│   └───────────┬───────────────────────────────────────┬──────────────────┘    │
│               │                                       │                        │
│        ┌──────▼──────┐                        ┌───────▼─────┐                  │
│        │    VM-1     │                        │    VM-2     │                  │
│        │192.168.100.2│                        │192.168.100.3│                  │
│        │             │                        │             │                  │
│        │ No WG needed│                        │ No WG needed│                  │
│        │ Routes via  │                        │ Routes via  │                  │
│        │ 192.168.100.1                        │ 192.168.100.1                  │
│        └─────────────┘                        └─────────────┘                  │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ WireGuard Tunnel
                                      │ (Direct P2P)
                                      │
┌────────────────────────────────────────────────────────────────────────────────┐
│                              BARE METAL 2                                       │
│                          Public IP: 51.38.54.39                                │
│                                                                                │
│   ┌──────────────────────────────────────────────────────────────────────┐    │
│   │                         Mesh Agent (ikto/netclient)                   │    │
│   │                                                                       │    │
│   │   Interface: wg-mesh                                                  │    │
│   │   Mesh IP: 10.10.0.2/16                                               │    │
│   │   Listen Port: UDP 51820                                              │    │
│   │   Public Endpoint: 51.38.54.39:51820                                  │    │
│   └───────────────────────────────┬──────────────────────────────────────┘    │
│                                   │                                            │
│   Routes:                         │                                            │
│   • 10.10.0.0/16 dev wg-mesh     │                                            │
│   • 192.168.100.0/24 via 10.10.0.1  (remote VMs)                              │
│                                   │                                            │
│   ┌───────────────────────────────▼──────────────────────────────────────┐    │
│   │                           vmbridge                                    │    │
│   │                        192.168.200.1/24                               │    │
│   └───────────┬───────────────────────────────────────┬──────────────────┘    │
│               │                                       │                        │
│        ┌──────▼──────┐                        ┌───────▼─────┐                  │
│        │    VM-3     │                        │    VM-4     │                  │
│        │192.168.200.2│                        │192.168.200.3│                  │
│        │             │                        │             │                  │
│        │ No WG needed│                        │ No WG needed│                  │
│        └─────────────┘                        └─────────────┘                  │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Best performance (single WG hop) | Requires different VM subnet per host OR overlay routing |
| No NAT traversal issues | More complex routing setup |
| Simpler VMs (no WG inside) | Bare metal becomes critical path |
| Scales to many VMs per host | Initial setup more involved |
| Single mesh node per host | |

### When to Use

- Large scale deployments (many VMs per host)
- Production environments
- When you control the bare metal configuration
- Following the Ravel/ikto architecture pattern

---

## Solution 5: Replace Netmaker with ikto

### How It Works

ikto is simpler than Netmaker and gives you explicit control over:
- `advertise_address` - The public IP peers use to reach you
- `wg_port` - The exact WireGuard port
- No auto-detection magic that can fail

### When to Consider

- Netmaker's auto-detection keeps failing
- You want predictable, explicit configuration
- You're already using NATS or willing to set it up
- You prefer simpler tools with less magic

### Implementation Overview

See [ikto-wg-connection-flow.md](ikto-wg-connection-flow.md) for detailed ikto documentation.

Basic steps:
1. Set up NATS server (or use existing)
2. Install ikto on each node (VM or bare metal)
3. Configure with explicit addresses and ports
4. Combine with Solution 2 or 3 for port forwarding

---

## Recommendation

### For Immediate Fix
**Use Solution 1 (Netmaker Relay)** - Takes 5 minutes, no code changes.

### For Production
**Use Solution 3 (Dynamic Port Forwarding)** - Best balance of automation and direct P2P performance.

### For Scale (Many VMs)
**Use Solution 4 (Bare Metal Mesh)** - Most efficient for large deployments.

### Decision Tree

```
                     Start Here
                         │
                         ▼
              ┌─────────────────────┐
              │ Need immediate fix? │
              └──────────┬──────────┘
                         │
              ┌──────────┴──────────┐
              │                     │
              ▼                     ▼
             Yes                   No
              │                     │
              ▼                     ▼
      ┌───────────────┐   ┌─────────────────────┐
      │ Solution 1:   │   │ How many VMs per    │
      │ Netmaker Relay│   │ bare metal host?    │
      └───────────────┘   └──────────┬──────────┘
                                     │
                          ┌──────────┴──────────┐
                          │                     │
                          ▼                     ▼
                       1-5 VMs              5+ VMs
                          │                     │
                          ▼                     ▼
                  ┌───────────────┐    ┌───────────────┐
                  │ Solution 3:   │    │ Solution 4:   │
                  │ Dynamic Port  │    │ Bare Metal    │
                  │ Forwarding    │    │ Mesh          │
                  └───────────────┘    └───────────────┘
```

---

## Quick Commands Reference

### Solution 1: Enable Relay
```bash
# Via Netmaker dashboard or:
sudo netclient pull  # After enabling relay on server
```

### Solution 2: Static Port Forward
```bash
# Add rules
sudo iptables -I FORWARD -p udp -d <VM_IP> --dport <WG_PORT> -j ACCEPT
sudo iptables -t nat -A PREROUTING -i <EXT_IF> -p udp --dport <WG_PORT> -j DNAT --to-destination <VM_IP>:<WG_PORT>

# Fix endpoint
sudo wg set netmaker peer <PEER_PUBKEY> endpoint <PEER_IP>:<CORRECT_PORT>
```

### Solution 3: Apply Script Changes
```bash
# After modifying scripts, recreate VMs:
sudo make vm-delete ID=34
sudo make vm-create ID=34
make vm-start ID=34
```

### Solution 4: Bare Metal Mesh
```bash
# Install on bare metal
sudo netclient join -t <TOKEN>
# Or
ikto agent -c /etc/ikto/config.json

# Add routes
sudo ip route add <REMOTE_VM_SUBNET> via <REMOTE_MESH_IP> dev wg-mesh
```
