# VM Mesh Networking Problem Analysis

This document explains the networking problem encountered when trying to establish WireGuard mesh connectivity between VMs running on different bare metal hosts using Netmaker.

## Current Architecture

```
                                    NETMAKER SERVER
                                   ┌─────────────────┐
                                   │  100.123.183.1  │
                                   │  (Control Plane)│
                                   └────────┬────────┘
                                            │
                          ┌─────────────────┴─────────────────┐
                          │         Internet/WAN              │
                          └─────────────────┬─────────────────┘
                                            │
              ┌─────────────────────────────┴─────────────────────────────┐
              │                                                           │
              ▼                                                           ▼
┌─────────────────────────────────────┐         ┌─────────────────────────────────────┐
│     BARE METAL 1 (bm-94-139)        │         │     BARE METAL 2 (other host)       │
│     Public IP: 54.38.94.139         │         │     Public IP: 51.38.54.39          │
│                                     │         │                                     │
│  ┌───────────────────────────────┐  │         │  ┌───────────────────────────────┐  │
│  │  iptables FORWARD policy: DROP│  │         │  │  iptables FORWARD policy: DROP│  │
│  │                               │  │         │  │                               │  │
│  │  Rules:                       │  │         │  │  Rules:                       │  │
│  │  ✓ vmbridge→eno1 ACCEPT      │  │         │  │  ✓ vmbridge→ext ACCEPT        │  │
│  │  ✓ eno1→vmbridge ESTABLISHED │  │         │  │  ✓ ext→vmbridge ESTABLISHED   │  │
│  │  ✗ NEW incoming UDP = DROP   │  │         │  │  ✗ NEW incoming UDP = DROP    │  │
│  └───────────────────────────────┘  │         │  └───────────────────────────────┘  │
│                                     │         │                                     │
│  ┌─────────────────────────────┐    │         │    ┌─────────────────────────────┐  │
│  │        vmbridge             │    │         │    │        vmbridge             │  │
│  │     192.168.200.1/24        │    │         │    │     192.168.100.1/24        │  │
│  └─────────────┬───────────────┘    │         │    └─────────────┬───────────────┘  │
│                │                    │         │                  │                  │
│         ┌──────┴──────┐             │         │           ┌──────┴──────┐           │
│         │   tap34     │             │         │           │   tap23     │           │
│         └──────┬──────┘             │         │           └──────┬──────┘           │
│                │                    │         │                  │                  │
│  ┌─────────────┴─────────────┐      │         │    ┌─────────────┴─────────────┐    │
│  │         VM-34             │      │         │    │         VM-23             │    │
│  │  ens4: 192.168.200.35     │      │         │    │  ens4: 192.168.100.24     │    │
│  │                           │      │         │    │                           │    │
│  │  ┌─────────────────────┐  │      │         │    │  ┌─────────────────────┐  │    │
│  │  │ netmaker interface  │  │      │         │    │  │ netmaker interface  │  │    │
│  │  │ IP: 100.123.183.2   │  │      │         │    │  │ IP: 100.123.183.3   │  │    │
│  │  │ WG Port: UDP 51822  │  │      │         │    │  │ WG Port: UDP 51824  │  │    │
│  │  └─────────────────────┘  │      │         │    │  └─────────────────────┘  │    │
│  └───────────────────────────┘      │         │    └───────────────────────────┘    │
│                                     │         │                                     │
└─────────────────────────────────────┘         └─────────────────────────────────────┘
```

## The Problem

Both VMs successfully connected to the Netmaker server but **cannot reach each other** over the mesh network.

### Symptom

```bash
# From VM-34
cloud@vm-34:~$ ping 100.123.183.3
PING 100.123.183.3 (100.123.183.3) 56(84) bytes of data.
^C
--- 100.123.183.3 ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2050ms

# From VM-23
cloud@vm-23:~$ ping 100.123.183.2
PING 100.123.183.2 (100.123.183.2) 56(84) bytes of data.
^C
--- 100.123.183.2 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1005ms
```

### Evidence from WireGuard

```bash
# VM-34's WireGuard status
cloud@vm-34:~$ sudo wg
interface: netmaker
  public key: JqcqIheNKSq0CqmagWlfTmepDwpc3ab+1xdf/MpJ1R0=
  private key: (hidden)
  listening port: 51822

peer: 0UDmH+NU30jCPtS/BqzvqnS/p2or7pYsmuaHdtvhhSM=
  endpoint: 103.191.50.49:443
  allowed ips: 100.123.183.1/32
  latest handshake: 25 seconds ago          ← Server connection WORKS
  transfer: 308 B received, 956 B sent

peer: COd63R1j6ibFCmBXJJxlPf7+3aC60YKXbaCtjXMthBQ=
  endpoint: 51.38.54.39:51821               ← WRONG PORT (should be 51824)
  allowed ips: 100.123.183.3/32
  transfer: 0 B received, 7.08 KiB sent     ← SENDING BUT NO RESPONSE
  persistent keepalive: every 20 seconds
```

```bash
# VM-23's WireGuard status
cloud@vm-23:~$ sudo wg
interface: netmaker
  public key: COd63R1j6ibFCmBXJJxlPf7+3aC60YKXbaCtjXMthBQ=
  private key: (hidden)
  listening port: 51824

peer: 0UDmH+NU30jCPtS/BqzvqnS/p2or7pYsmuaHdtvhhSM=
  endpoint: 103.191.50.49:443
  allowed ips: 100.123.183.1/32
  latest handshake: 16 seconds ago          ← Server connection WORKS
  transfer: 308 B received, 924 B sent

peer: JqcqIheNKSq0CqmagWlfTmepDwpc3ab+1xdf/MpJ1R0=
  endpoint: 54.38.94.139:51821              ← WRONG PORT (should be 51822)
  allowed ips: 100.123.183.2/32
  transfer: 0 B received, 6.94 KiB sent     ← SENDING BUT NO RESPONSE
  persistent keepalive: every 20 seconds
```

---

## Root Cause Analysis

### Problem #1: Wrong Endpoint Ports

Netmaker auto-detected **incorrect ports** for peer endpoints:

| VM | Actual WG Port | Endpoint Seen by Peer | Issue |
|----|----------------|----------------------|-------|
| VM-34 | UDP 51822 | 54.38.94.139:**51821** | Wrong port |
| VM-23 | UDP 51824 | 51.38.54.39:**51821** | Wrong port |

**Why this happened:** Port 51821 is the **netclient daemon TCP port**, not the WireGuard UDP port. Netmaker's endpoint detection got confused by NAT.

### Problem #2: No Port Forwarding (DNAT)

Even with correct ports, the bare metal hosts have **no DNAT rules** to forward incoming UDP traffic to the VMs.

```bash
# On bare metal bm-94-139
ubuntu@bm-94-139:~$ sudo iptables -t nat -L PREROUTING -n -v
Chain PREROUTING (policy ACCEPT)
# No rules to forward UDP 51822 → VM-34 (192.168.200.35)
```

### Problem #3: FORWARD Chain Drops New Connections

The bare metal's iptables FORWARD chain has a **DROP policy** and only allows ESTABLISHED/RELATED connections for incoming traffic:

```bash
ubuntu@bm-94-139:~$ sudo iptables -L FORWARD -n -v
Chain FORWARD (policy DROP 1944 packets, 939K bytes)
 pkts bytes target     prot opt in     out     source               destination
...
14166 1115K ACCEPT     all  --  vmbridge eno1    0.0.0.0/0            0.0.0.0/0
16485   60M ACCEPT     all  --  eno1   vmbridge  0.0.0.0/0            0.0.0.0/0   state RELATED,ESTABLISHED
                                                                       ↑
                                                          Only allows responses to
                                                          outbound connections, NOT
                                                          new incoming connections!
```

---

## Packet Flow Analysis

### What Happens When VM-34 Pings VM-23

```
Step 1: VM-34 initiates ping to mesh IP
┌─────────────────┐
│     VM-34       │
│ 192.168.200.35  │
│                 │
│ ping 100.123.183.3
│        │
│        ▼
│ WireGuard encrypts
│        │
│        ▼
│ UDP packet created:
│ src: 192.168.200.35:random
│ dst: 51.38.54.39:51821      ← Wrong port, but let's follow the packet
└────────┬────────┘
         │
         ▼
Step 2: Packet traverses bare metal 1
┌─────────────────┐
│    vmbridge     │
│  192.168.200.1  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   iptables      │
│   FORWARD       │
│                 │
│ vmbridge→eno1   │
│    ACCEPT ✓     │  ← Outbound traffic allowed
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   NAT/MASQ      │
│                 │
│ src becomes:    │
│ 54.38.94.139:X  │  ← Bare metal's public IP (SNAT)
└────────┬────────┘
         │
         ▼
    ═══════════════
       INTERNET
    ═══════════════
         │
         ▼
Step 3: Packet arrives at bare metal 2 - THE FAILURE POINT
┌─────────────────────────────────────────────────────────────────┐
│              BARE METAL 2 (51.38.54.39)                         │
│                                                                 │
│   Incoming UDP packet:                                          │
│   src: 54.38.94.139:X                                           │
│   dst: 51.38.54.39:51821                                        │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    iptables                              │   │
│   │                                                          │   │
│   │  1. PREROUTING (nat table)                               │   │
│   │     - No DNAT rule for port 51821                        │   │
│   │     - Packet destination unchanged                       │   │
│   │                                                          │   │
│   │  2. Routing decision                                     │   │
│   │     - Destination is local IP (51.38.54.39)              │   │
│   │     - But port 51821 has no listener on bare metal       │   │
│   │     - OR if it needs forwarding to VM...                 │   │
│   │                                                          │   │
│   │  3. FORWARD chain (if forwarding needed)                 │   │
│   │     - Policy: DROP                                       │   │
│   │     - No rule matches UDP to VM                          │   │
│   │                                                          │   │
│   │     ╔═══════════════════════════════════════════════╗    │   │
│   │     ║           PACKET DROPPED HERE ✗              ║    │   │
│   │     ╚═══════════════════════════════════════════════╝    │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   VM-23 at 192.168.100.24:51824 NEVER receives the packet       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Summary Table

| Component | Current State | Required State |
|-----------|--------------|----------------|
| VM-34 WG Listen Port | UDP 51822 | 51822 (correct) |
| VM-23 WG Listen Port | UDP 51824 | 51824 (correct) |
| Peer endpoint for VM-23 | 51.38.54.39:**51821** | 51.38.54.39:**51824** |
| Peer endpoint for VM-34 | 54.38.94.139:**51821** | 54.38.94.139:**51822** |
| BM1 DNAT for port 51822 | Missing | Forward to 192.168.200.35:51822 |
| BM2 DNAT for port 51824 | Missing | Forward to 192.168.100.24:51824 |
| BM1 FORWARD rule for UDP | Drops new connections | Allow UDP to VM's WG port |
| BM2 FORWARD rule for UDP | Drops new connections | Allow UDP to VM's WG port |

---

## Solutions

### Solution 1: Static Fix (Manual)

Add iptables rules on each bare metal host:

**On Bare Metal 1 (bm-94-139) for VM-34:**
```bash
# Allow forwarding UDP to VM's WireGuard port
sudo iptables -I FORWARD -p udp -d 192.168.200.35 --dport 51822 -j ACCEPT

# DNAT: Forward incoming UDP 51822 to VM
sudo iptables -t nat -A PREROUTING -i eno1 -p udp --dport 51822 -j DNAT --to-destination 192.168.200.35:51822
```

**On Bare Metal 2 for VM-23:**
```bash
# Allow forwarding UDP to VM's WireGuard port
sudo iptables -I FORWARD -p udp -d 192.168.100.24 --dport 51824 -j ACCEPT

# DNAT: Forward incoming UDP 51824 to VM
sudo iptables -t nat -A PREROUTING -i <ext-interface> -p udp --dport 51824 -j DNAT --to-destination 192.168.100.24:51824
```

**Fix WireGuard endpoints:**
```bash
# On VM-34
sudo wg set netmaker peer COd63R1j6ibFCmBXJJxlPf7+3aC60YKXbaCtjXMthBQ= endpoint 51.38.54.39:51824

# On VM-23
sudo wg set netmaker peer JqcqIheNKSq0CqmagWlfTmepDwpc3ab+1xdf/MpJ1R0= endpoint 54.38.94.139:51822
```

### Solution 2: Dynamic Fix (Integrated into VM Lifecycle)

Modify `vm-create.sh` and `vm-delete.sh` to automatically manage port forwarding rules when VMs are created/deleted. See `docs/netmaker.md` for implementation details.

### Solution 3: Netmaker Relay Mode

Enable relay in Netmaker dashboard so traffic flows through the server when direct P2P fails:
1. Go to Networks → vm-mesh → Nodes
2. Select the Netmaker server node
3. Enable "Relay" functionality
4. Configure other nodes to use relay

### Solution 4: Run Mesh on Bare Metal (ikto Pattern)

Instead of running WireGuard inside VMs, run the mesh agent on bare metal hosts and route VM traffic through the host's mesh interface. See `docs/ikto-wg-connection-flow.md` for this architecture.

---

## Related Documentation

- [Netmaker Integration Guide](netmaker.md)
- [ikto WireGuard Connection Flow](ikto-wg-connection-flow.md)
- [Multi-VM Architecture](multi-vm-architecture.md)
