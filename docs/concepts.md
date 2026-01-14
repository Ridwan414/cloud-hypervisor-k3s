# Networking Concepts: NAT, Hole Punching & WireGuard

A comprehensive guide to understanding network address translation, NAT traversal, and WireGuard mesh networking.

---

## Table of Contents

1. [Why NAT Exists](#part-1-why-nat-exists)
2. [How NAT Works Internally](#part-2-how-nat-works-internally)
3. [Types of NAT](#part-3-types-of-nat)
4. [STUN (Session Traversal Utilities for NAT)](#part-4-stun-session-traversal-utilities-for-nat)
5. [UDP Hole Punching](#part-5-udp-hole-punching)
6. [Connection Tracking (conntrack)](#part-6-connection-tracking-conntrack)
7. [iptables and Packet Flow](#part-7-iptables-and-packet-flow)
8. [Port Forwarding (DNAT)](#part-8-port-forwarding-dnat)
9. [WireGuard Handshake](#part-9-wireguard-handshake)
10. [Real-World Problem Analysis](#part-10-real-world-problem-analysis)
11. [Solutions](#part-11-solutions)

---

## Part 1: Why NAT Exists

### The IPv4 Problem

```
Total IPv4 addresses:     4,294,967,296 (4.3 billion)
Devices in the world:     ~30 billion
Problem:                  Not enough addresses!

Solution:                 NAT (Network Address Translation)
Idea:                     Share one public IP among many devices
```

### How NAT Solves This

```
WITHOUT NAT (impossible today):
────────────────────────────────────────────────
Every device needs public IP:
  Phone:     203.0.113.1
  Laptop:    203.0.113.2
  TV:        203.0.113.3
  Fridge:    203.0.113.4
  ...

Not enough IPs for everyone!


WITH NAT (what we use):
────────────────────────────────────────────────
Your home/server:
  Router/Host has ONE public IP:  203.0.113.1

  Inside (private IPs):
    Phone:   192.168.1.10
    Laptop:  192.168.1.11
    TV:      192.168.1.12
    VM-1:    192.168.1.13

  All share the ONE public IP through NAT
```

### Private IP Ranges (RFC 1918)

These IPs are **private** - not routable on the internet:

| Range | CIDR | Total IPs | Common Use |
|-------|------|-----------|------------|
| 10.0.0.0 - 10.255.255.255 | 10.0.0.0/8 | 16 million | Large networks, cloud |
| 172.16.0.0 - 172.31.255.255 | 172.16.0.0/12 | 1 million | Medium networks |
| 192.168.0.0 - 192.168.255.255 | 192.168.0.0/16 | 65,536 | Home networks, VMs |

**Example:**
- VMs use: `192.168.100.x` (private)
- Bare Metal hosts use: `51.38.x.x`, `54.38.x.x` (public)

---

## Part 2: How NAT Works Internally

### The NAT Translation Table

NAT maintains a translation table mapping internal addresses to external:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        NAT TRANSLATION TABLE                         │
├───────────────────────────┬─────────────────────────┬───────────────┤
│     Internal (Private)    │    External (Public)     │    State     │
├───────────────────────────┼─────────────────────────┼───────────────┤
│  192.168.100.13:51823     │  51.38.54.39:31344      │   ACTIVE     │
│  192.168.100.12:51822     │  51.38.54.39:40963      │   ACTIVE     │
│  192.168.100.13:38242     │  51.38.54.39:38242      │   ACTIVE     │
└───────────────────────────┴─────────────────────────┴───────────────┘
```

### Outbound Packet Flow (Private → Internet)

Step-by-step when a VM sends a packet:

```
1. VM creates packet:
   ┌─────────────────────────────────────┐
   │  Source:      192.168.100.13:51823  │  ← Private IP
   │  Destination: 54.38.94.139:443      │  ← Remote server
   │  Data:        [WireGuard handshake] │
   └─────────────────────────────────────┘

2. Packet arrives at NAT (host):
   NAT says: "Private IP can't go on internet, let me translate"

3. NAT creates mapping:
   192.168.100.13:51823 ↔ 51.38.54.39:31344

4. NAT rewrites packet:
   ┌─────────────────────────────────────┐
   │  Source:      51.38.54.39:31344     │  ← Now public IP!
   │  Destination: 54.38.94.139:443      │
   │  Data:        [WireGuard handshake] │
   └─────────────────────────────────────┘

5. Packet goes to internet with public IP
```

### Inbound Packet Flow (Internet → Private)

When a reply comes back:

```
1. Reply packet arrives at host:
   ┌─────────────────────────────────────┐
   │  Source:      54.38.94.139:443      │
   │  Destination: 51.38.54.39:31344     │  ← Public IP:port
   │  Data:        [WireGuard response]  │
   └─────────────────────────────────────┘

2. NAT looks up table:
   "51.38.54.39:31344 maps to 192.168.100.13:51823"

3. NAT rewrites and forwards:
   ┌─────────────────────────────────────┐
   │  Source:      54.38.94.139:443      │
   │  Destination: 192.168.100.13:51823  │  ← Back to private IP
   │  Data:        [WireGuard response]  │
   └─────────────────────────────────────┘

4. VM receives the packet ✓
```

### The Problem: Unsolicited Inbound

What if someone **initiates** a connection to your VM?

```
1. External server sends packet:
   ┌─────────────────────────────────────┐
   │  Source:      54.38.94.139:443      │
   │  Destination: 51.38.54.39:31344     │
   │  Data:        [Hello!]              │
   └─────────────────────────────────────┘

2. NAT receives packet, looks up table:
   "51.38.54.39:31344... do I have a mapping?"

   IF no prior outbound connection:
   "No mapping exists. I don't know which internal device wants this."

3. NAT DROPS the packet ❌
```

> **Key Insight:** NAT's blocking of unsolicited inbound is a **security feature** - it prevents random internet hosts from reaching your private devices.

---

## Part 3: Types of NAT

### NAT Behavior Types (RFC 3489)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              NAT TYPES                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. FULL CONE NAT (Most permissive)                                         │
│     ─────────────────────────────────                                        │
│     Once mapping created: internal:port ↔ external:port                     │
│     ANY external host can send to external:port                             │
│                                                                              │
│     Traversal: Easy ✓                                                        │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  2. RESTRICTED CONE NAT                                                      │
│     ──────────────────────                                                   │
│     Only hosts that internal device has sent to can reply                   │
│     Port doesn't matter, only IP                                            │
│                                                                              │
│     Traversal: Medium difficulty                                             │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  3. PORT RESTRICTED CONE NAT                                                 │
│     ───────────────────────────                                              │
│     Only exact IP:port that internal device sent to can reply               │
│                                                                              │
│     Traversal: Harder                                                        │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  4. SYMMETRIC NAT (Most restrictive)                                         │
│     ─────────────────────────────────                                        │
│     Different external port for EACH destination!                           │
│                                                                              │
│     VM → Server A: gets external port 31344                                 │
│     VM → Server B: gets external port 28317 (different!)                    │
│                                                                              │
│     Traversal: Very hard ❌                                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Visual Comparison

**Full Cone NAT:**
```
Internal 192.168.1.10:5000 ↔ External 1.2.3.4:6000

Anyone can send to 1.2.3.4:6000 → reaches 192.168.1.10:5000
```

**Symmetric NAT:**
```
Internal 192.168.1.10:5000 → Server A → External 1.2.3.4:6000
Internal 192.168.1.10:5000 → Server B → External 1.2.3.4:7000  ← Different!
Internal 192.168.1.10:5000 → Server C → External 1.2.3.4:8000  ← Different!

Each destination gets different external port!
Server B cannot send to port 6000 - it won't work!
```

### NAT Type Comparison Table

| NAT Type | External Port | Who Can Send Inbound | Hole Punch Success |
|----------|---------------|----------------------|-------------------|
| Full Cone | Same for all destinations | Anyone | High |
| Restricted Cone | Same for all destinations | Only IPs you contacted | High |
| Port Restricted | Same for all destinations | Only IP:port you contacted | Medium |
| Symmetric | Different per destination | Only exact IP:port you contacted | Low |

---

## Part 4: STUN (Session Traversal Utilities for NAT)

### What is STUN?

STUN helps devices discover their public IP and port after NAT translation.

**Problem:** Your VM knows its private IP (192.168.100.13) but doesn't know its public IP after NAT translation.

**Solution:** Ask a STUN server!

### How STUN Works

```
┌─────────────┐                    ┌─────────────────┐
│    VM       │                    │   STUN Server   │
│192.168.100.13                    │ 74.125.250.129  │
└──────┬──────┘                    │  (Google)       │
       │                           └────────┬────────┘
       │                                    │
       │  1. "What's my public IP:port?"    │
       │ ──────────────────────────────────►│
       │    (UDP from internal:33098)       │
       │                                    │
       │                           NAT translates to
       │                           external:28317
       │                                    │
       │  2. "You are 51.38.54.39:28317"   │
       │ ◄──────────────────────────────────│
       │                                    │

VM now knows: "My public endpoint is 51.38.54.39:28317"
```

### STUN's Limitation with Symmetric NAT

```
THE PROBLEM:
────────────

1. VM asks STUN server (destination A):
   Internal: 192.168.100.13:33098 → STUN Server
   NAT assigns: external port 28317
   STUN replies: "You are 51.38.54.39:28317"

2. VM sends to peer (destination B):
   Internal: 192.168.100.13:51823 → Peer
   NAT assigns: external port 31344  ← DIFFERENT PORT!

3. Peer tries to reach 51.38.54.39:28317 (from STUN)
   But actual port is 31344
   FAILS!
```

**Why it fails:**
- STUN query used different local port (33098)
- Even with same local port, Symmetric NAT assigns different external port per destination

### STUN Servers (Public)

| Provider | Address |
|----------|---------|
| Google | stun.l.google.com:19302 |
| Cloudflare | stun.cloudflare.com:3478 |
| Twilio | global.stun.twilio.com:3478 |

---

## Part 5: UDP Hole Punching

### The Concept

**Goal:** Two devices behind NAT want to connect directly

**Problem:** Both NATs block unsolicited inbound

**Solution:** "Punch holes" in both NATs simultaneously

### How Hole Punching Works (Ideal Case)

```
┌─────────────┐         ┌──────────────┐         ┌─────────────┐
│   Device A  │         │    Server    │         │   Device B  │
│   (NAT 1)   │         │  (Public)    │         │   (NAT 2)   │
└──────┬──────┘         └──────┬───────┘         └──────┬──────┘
       │                       │                        │
       │  1. Register          │         2. Register    │
       │ ─────────────────────►│◄───────────────────────│
       │  "I'm at 1.1.1.1:100" │  "I'm at 2.2.2.2:200" │
       │                       │                        │
       │  3. Here's your peer  │  3. Here's your peer   │
       │ ◄─────────────────────│───────────────────────►│
       │  "B is at 2.2.2.2:200"│  "A is at 1.1.1.1:100"│
       │                       │                        │
       │  4. Send UDP packet   │                        │
       │ ══════════════════════════════════════════════►│
       │     to 2.2.2.2:200    │                        │
       │                       │                        │
       │     NAT 1 creates mapping for outbound        │
       │                       │                        │
       │                       │    5. Send UDP packet  │
       │ ◄══════════════════════════════════════════════│
       │                       │       to 1.1.1.1:100   │
       │                       │                        │
       │     NAT 1 sees: "I have mapping, allow!"      │
       │                       │                        │
       │  6. HOLE PUNCHED! ✓   │                        │
       │ ◄════════════════════════════════════════════►│
       │     Direct connection!│                        │
```

### Why Hole Punching Fails

```
FAILURE SCENARIO:
─────────────────

1. Device A does STUN, discovers 1.1.1.1:28317
   Server records: "A = 1.1.1.1:28317"

2. Device A sends packet to B (2.2.2.2:200)
   NAT creates NEW mapping: internal → external:31344
   (Different port because Symmetric NAT)

3. Device B tries to reach A at 1.1.1.1:28317 (from STUN)

4. Packet arrives at NAT 1 on port 28317
   NAT says: "Port 28317? No mapping exists!"

   Existing mapping is: 31344 ↔ 2.2.2.2:200
   Packet came to: 28317
   NO MATCH → DROP! ❌

5. Same happens in reverse direction
   Both sides dropping packets
   Hole punch FAILS!
```

### Conditions for Successful Hole Punching

| Condition | Required | Why |
|-----------|----------|-----|
| Both devices know peer's endpoint | Yes | Need destination address |
| NAT creates predictable mappings | Yes | STUN-discovered port must match actual port |
| Packets sent nearly simultaneously | Yes | NAT mappings have timeout |
| No firewall blocking UDP | Yes | UDP must pass through |
| Non-symmetric NAT | Preferred | Symmetric NAT changes ports per destination |

---

## Part 6: Connection Tracking (conntrack)

### What is Conntrack?

**conntrack** = Connection Tracking

Linux kernel module that tracks all network connections.

**Purpose:**
- Remember "conversations" between hosts
- Allow related/reply packets through firewall
- Enable stateful firewalling

### Conntrack Entry Explained

Example entry:
```
udp 17 29 src=192.168.100.13 dst=54.38.94.139 sport=51823 dport=443 [UNREPLIED] src=54.38.94.139 dst=51.38.54.39 sport=443 dport=31344
```

Breakdown:

| Field | Value | Meaning |
|-------|-------|---------|
| `udp` | Protocol | UDP protocol |
| `17` | Protocol number | 17 = UDP |
| `29` | Timeout | Seconds until entry expires |
| **Original Direction** | | Outbound from VM |
| `src=192.168.100.13` | Source | VM's private IP |
| `dst=54.38.94.139` | Destination | Remote server |
| `sport=51823` | Source port | WireGuard port |
| `dport=443` | Dest port | Remote WireGuard |
| `[UNREPLIED]` | State | **No reply received!** |
| **Reply Direction** | | Expected response |
| `src=54.38.94.139` | Reply from | Remote server |
| `dst=51.38.54.39` | Reply to | Public IP (after NAT) |
| `sport=443` | Reply from port | Remote's port |
| `dport=31344` | Reply to port | NAT's external port |

### Conntrack States

```
┌─────────────────────────────────────────────────────────────────┐
│                     CONNTRACK STATES                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  [UNREPLIED]                                                     │
│  ────────────                                                    │
│  Packet sent, but no reply received yet                         │
│  Connection is one-way so far                                   │
│  Indicates: replies not coming back (problem!)                  │
│                                                                  │
│  [ASSURED]                                                       │
│  ──────────                                                      │
│  Both directions have traffic                                   │
│  Connection is established and working                          │
│  Won't be dropped even under memory pressure                    │
│                                                                  │
│  NEW                                                             │
│  ───                                                             │
│  Brand new connection, just started                             │
│                                                                  │
│  ESTABLISHED                                                     │
│  ───────────                                                     │
│  Connection has seen traffic in both directions                 │
│                                                                  │
│  RELATED                                                         │
│  ───────                                                         │
│  Related to an existing connection (e.g., FTP data)             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Useful Conntrack Commands

```bash
# List all connections
sudo conntrack -L

# Filter by destination IP
sudo conntrack -L | grep "dst=54.38.94.139"

# Filter by port
sudo conntrack -L | grep "dport=443"

# Watch connections in real-time
sudo conntrack -E

# Count connections
sudo conntrack -C
```

---

## Part 7: iptables and Packet Flow

### Linux Packet Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        IPTABLES PACKET FLOW                                  │
└─────────────────────────────────────────────────────────────────────────────┘

INCOMING PACKET (from internet):
────────────────────────────────

    Internet
        │
        ▼
┌───────────────┐
│  PREROUTING   │  ← NAT happens here (DNAT)
│   (nat)       │    "Change destination IP/port"
└───────┬───────┘
        │
        ▼
   ┌─────────┐
   │ Routing │  → Is packet for this host or needs forwarding?
   │Decision │
   └────┬────┘
        │
   ┌────┴────────────────┐
   │                     │
   ▼                     ▼
┌─────────┐         ┌─────────┐
│  INPUT  │         │ FORWARD │  ← For packets going through (to VMs)
│         │         │         │    Filtering happens here!
└────┬────┘         └────┬────┘
     │                   │
     ▼                   ▼
Local Process      ┌───────────────┐
(host itself)      │  POSTROUTING  │  ← NAT happens here (SNAT/MASQUERADE)
                   │    (nat)      │    "Change source IP/port"
                   └───────┬───────┘
                           │
                           ▼
                     To destination
                     (VM via bridge)
```

### iptables Tables and Chains

| Table | Purpose | Chains |
|-------|---------|--------|
| **filter** | Packet filtering (allow/deny) | INPUT, FORWARD, OUTPUT |
| **nat** | Network Address Translation | PREROUTING, OUTPUT, POSTROUTING |
| **mangle** | Packet modification | All chains |
| **raw** | Bypass connection tracking | PREROUTING, OUTPUT |

### Common iptables Rules Explained

```bash
# Allow established connections (replies)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# This means:
# -A FORWARD          : Append to FORWARD chain
# -m state            : Use state matching module
# --state ESTABLISHED : Match established connections
# --state RELATED     : Match related connections (like FTP data)
# -j ACCEPT           : Jump to ACCEPT (allow packet)
```

```bash
# NAT masquerade (outbound NAT)
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# This means:
# -t nat              : Use nat table
# -A POSTROUTING      : Append to POSTROUTING chain
# -o eth0             : Match packets going out eth0
# -j MASQUERADE       : Replace source IP with interface IP
```

### The FORWARD Chain Problem

```
Typical FORWARD chain configuration:

Chain FORWARD (policy DROP)        ← DEFAULT IS DROP!

ACCEPT  all  --  vmbridge  eth0    ← VM → Internet (outbound) ✓

ACCEPT  all  --  eth0  vmbridge  state RELATED,ESTABLISHED
                                   ↑
                                   Only allows REPLIES!
                                   New inbound = DROPPED!
```

**Why this matters:**
- Outbound from VMs works (first rule)
- Inbound replies work (second rule)
- **New inbound connections are DROPPED** (default policy)

---

## Part 8: Port Forwarding (DNAT)

### What is DNAT?

**DNAT** = Destination NAT

Changes the **destination** address of incoming packets.

> "When packet arrives for me:port, send it to internal_ip:port instead"

### How Port Forwarding Works

**Without Port Forwarding:**
```
Packet arrives: dst=51.38.54.39:51823
Host says: "That's my IP, but nothing listening on 51823"
Result: Packet dropped or rejected
```

**With Port Forwarding:**
```
Rule: Forward UDP 51823 → 192.168.100.13:51823

Packet arrives: dst=51.38.54.39:51823
PREROUTING: "Match! Rewrite destination"
New destination: 192.168.100.13:51823
Routing: "192.168.100.13 is on vmbridge, forward there"
FORWARD: Allows packet (if rule exists)
Result: VM receives packet ✓
```

### Complete Port Forwarding Setup

```bash
# Step 1: DNAT rule (rewrite destination)
# "Packets to my port 51823 should go to VM"
iptables -t nat -A PREROUTING -i eth0 -p udp --dport 51823 \
    -j DNAT --to-destination 192.168.100.13:51823

# Step 2: FORWARD rule (allow the forwarded packet)
# "Allow UDP packets destined for VM's port"
iptables -A FORWARD -p udp -d 192.168.100.13 --dport 51823 -j ACCEPT

# Step 3: Ensure return traffic is allowed
# "Allow reply packets back"
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
```

### Port Forwarding Diagram

```
BEFORE (no port forwarding):
─────────────────────────────

Internet ──► 51.38.54.39:51823 ──► ??? (nothing listening) ──► DROPPED


AFTER (with port forwarding):
──────────────────────────────

Internet ──► 51.38.54.39:51823
                   │
                   ▼
             PREROUTING (DNAT)
             "Rewrite dst to 192.168.100.13:51823"
                   │
                   ▼
             FORWARD chain
             "Allow packet to VM"
                   │
                   ▼
             192.168.100.13:51823 (VM receives!) ✓
```

---

## Part 9: WireGuard Handshake

### WireGuard Overview

WireGuard is a modern VPN protocol that:
- Uses state-of-the-art cryptography
- Has minimal attack surface (~4000 lines of code)
- Works over UDP
- Uses public/private key pairs for authentication

### The Noise Protocol Handshake

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      WIREGUARD HANDSHAKE (Noise Protocol)                    │
└─────────────────────────────────────────────────────────────────────────────┘

Both peers have:
- Their own private key
- Their own public key
- Peer's public key (pre-shared via configuration)

STEP 1: Initiator sends Handshake Initiation
─────────────────────────────────────────────
┌────────────────────────────────────────┐
│  Handshake Initiation (148 bytes)      │
│                                        │
│  - Sender index (random)               │
│  - Encrypted ephemeral public key      │
│  - Encrypted static public key         │
│  - Encrypted timestamp                 │
│  - MAC (authentication)                │
└────────────────────────────────────────┘

STEP 2: Responder sends Handshake Response
─────────────────────────────────────────
┌────────────────────────────────────────┐
│  Handshake Response (92 bytes)         │
│                                        │
│  - Sender index                        │
│  - Receiver index (from initiation)    │
│  - Encrypted ephemeral public key      │
│  - Encrypted confirmation              │
│  - MAC                                 │
└────────────────────────────────────────┘

STEP 3: Session established
────────────────────────────
Both sides derive same symmetric keys
Encrypted tunnel is ready!
```

### Why Handshake Fails Through NAT

```
Initiator (VM-12) sends Handshake Initiation:
─────────────────────────────────────────────
  src: 192.168.100.13:51823
  dst: 54.38.94.139:443

  NAT translates to:
  src: 51.38.54.39:31344
  dst: 54.38.94.139:443

  But responder's NAT may drop this (no mapping)!


Responder (VM-2) sends Handshake Initiation:
────────────────────────────────────────────
  src: 192.168.200.3:443
  dst: 51.38.54.39:28317  ← Wrong port (from STUN)!

  NAT translates to:
  src: 54.38.94.139:443
  dst: 51.38.54.39:28317  ← Wrong port!

  Host receives on port 28317
  No NAT mapping exists for 28317 (actual is 31344)
  DROPPED! ❌


No handshake completion = No tunnel = No connectivity
```

### WireGuard Keepalive

```
WireGuard uses persistent keepalive to maintain NAT mappings:

Every 25 seconds (configurable):
  Send empty encrypted packet to peer

Purpose:
  - Keeps NAT mapping alive
  - Prevents timeout
  - Maintains connectivity through NAT

Configuration:
  PersistentKeepalive = 25
```

---

## Part 10: Real-World Problem Analysis

### Network Topology Example

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           NETWORK TOPOLOGY                                   │
└─────────────────────────────────────────────────────────────────────────────┘

                           ┌─────────────────────┐
                           │   NETMAKER SERVER   │
                           │   103.191.50.49     │
                           │                     │
                           │ Stores endpoints:   │
                           │ • VM-12: 51.38:28317│ ← STUN discovered (wrong!)
                           │ • VM-2: 54.38:443   │
                           └──────────┬──────────┘
                                      │
                    ┌─────────────────┴─────────────────┐
                    │              INTERNET              │
                    └─────────────────┬─────────────────┘
                                      │
           ┌──────────────────────────┴──────────────────────────┐
           │                                                      │
           ▼                                                      ▼
┌─────────────────────────────┐            ┌─────────────────────────────┐
│      BM1 (51.38.54.39)      │            │      BM2 (54.38.94.139)     │
│                             │            │                             │
│  ┌───────────────────────┐  │            │  ┌───────────────────────┐  │
│  │    iptables NAT       │  │            │  │    iptables NAT       │  │
│  │                       │  │            │  │                       │  │
│  │ Actual mapping:       │  │            │  │ Mapping:              │  │
│  │ 192.168.100.13:51823  │  │            │  │ 192.168.200.3:443     │  │
│  │    ↕                  │  │            │  │    ↕                  │  │
│  │ 51.38.54.39:31344     │  │            │  │ 54.38.94.139:????     │  │
│  │                       │  │            │  │                       │  │
│  │ STUN reported: 28317  │  │            │  │                       │  │
│  │ Actual port:   31344  │  │            │  │                       │  │
│  │ MISMATCH! ❌          │  │            │  │                       │  │
│  └───────────┬───────────┘  │            │  └───────────┬───────────┘  │
│              │              │            │              │              │
│      ┌───────┴───────┐      │            │      ┌───────┴───────┐      │
│      │   vmbridge    │      │            │      │   vmbridge    │      │
│      │192.168.100.1  │      │            │      │192.168.200.1  │      │
│      └───────┬───────┘      │            │      └───────┬───────┘      │
│              │              │            │              │              │
│      ┌───────┴───────┐      │            │      ┌───────┴───────┐      │
│      │    VM-12      │      │            │      │    VM-2       │      │
│      │192.168.100.13 │      │            │      │192.168.200.3  │      │
│      │  WG: 51823    │      │            │      │  WG: 443      │      │
│      │  Mesh IP:     │      │            │      │  Mesh IP:     │      │
│      │  100.123.183.3│      │            │      │  100.123.183.4│      │
│      └───────────────┘      │            │      └───────────────┘      │
└─────────────────────────────┘            └─────────────────────────────┘
```

### The Failure Chain

```
1. STUN DISCOVERY (wrong port recorded)
   ─────────────────────────────────────
   VM-12 → STUN Server: "What's my public endpoint?"
   STUN Server: "You are 51.38.54.39:28317"
   Netmaker stores: VM-12 = 51.38.54.39:28317

2. ACTUAL WIREGUARD TRAFFIC (different port)
   ──────────────────────────────────────────
   VM-12 → VM-2: Uses WireGuard port 51823
   NAT creates: 192.168.100.13:51823 ↔ 51.38.54.39:31344
   (Port 31344, NOT 28317!)

3. VM-2 TRIES TO REACH VM-12
   ─────────────────────────────
   VM-2 sends to: 51.38.54.39:28317 (from Netmaker)
   Packet arrives at BM1 port 28317
   BM1 NAT: "No mapping for port 28317!"
   DROPPED! ❌

4. VM-12 TRIES TO REACH VM-2
   ─────────────────────────────
   VM-12 sends to: 54.38.94.139:443
   NAT translates: src becomes 51.38.54.39:31344
   Packet arrives at BM2
   BM2 NAT: "No mapping for this!" (VM-2 hasn't sent to 31344)
   DROPPED! ❌

5. RESULT
   ────────
   Both directions fail
   No WireGuard handshake completes
   No tunnel established
   VMs cannot communicate
```

### Diagnostic Commands

```bash
# Check connection tracking
sudo conntrack -L | grep "54.38.94.139"

# Look for [UNREPLIED] entries - indicates one-way traffic
sudo conntrack -L | grep UNREPLIED

# Watch real-time connections
sudo conntrack -E

# Check iptables rules
sudo iptables -L FORWARD -n -v

# Check NAT rules
sudo iptables -t nat -L -n -v

# Capture UDP traffic on WireGuard ports
sudo tcpdump -i eth0 udp port 51820 or udp port 443

# Check WireGuard status
sudo wg show

# Check netclient status
sudo netclient list
```

---

## Part 11: Solutions

### Solution 1: Port Forwarding (DNAT)

**Concept:** Make ports static so NAT translation is predictable.

```bash
# On BM1 (51.38.54.39) - for VM-12
sudo iptables -t nat -A PREROUTING -i eno1 -p udp --dport 51823 \
    -j DNAT --to-destination 192.168.100.13:51823
sudo iptables -A FORWARD -p udp -d 192.168.100.13 --dport 51823 -j ACCEPT

# On BM2 (54.38.94.139) - for VM-2
sudo iptables -t nat -A PREROUTING -i eth0 -p udp --dport 443 \
    -j DNAT --to-destination 192.168.200.3:443
sudo iptables -A FORWARD -p udp -d 192.168.200.3 --dport 443 -j ACCEPT
```

Then update endpoints in Netmaker to use the forwarded ports.

| Pros | Cons |
|------|------|
| Direct peer-to-peer connection | Manual port management |
| Lowest latency | Need firewall changes |
| 100% reliable | Must update Netmaker endpoints |

### Solution 2: Relay Server

**Concept:** Route traffic through a server both peers can reach.

```
VM-12 → Netmaker Server → VM-2
VM-2 → Netmaker Server → VM-12

Both VMs connect OUTBOUND to server (always works through NAT)
Server forwards traffic between them
```

**Setup:** Enable relay in Netmaker dashboard:
1. Go to Hosts
2. Select Netmaker server node
3. Enable as Relay
4. Select which nodes should use relay

| Pros | Cons |
|------|------|
| No firewall changes needed | Higher latency |
| Works through any NAT | Server bandwidth bottleneck |
| Easy to set up | Single point of failure |

### Solution 3: WireGuard on Bare Metal Host

**Concept:** Remove double NAT by running WireGuard on host instead of VM.

```
Current (double NAT):
VM → BM NAT → Internet → BM NAT → VM
     ↑                      ↑
   Problem               Problem

Better (single layer):
BM ←──────── Internet ────────→ BM
(direct public IP connection, no NAT issue)
```

```bash
# On each BM host (not VM)
sudo apt install netclient
sudo netclient join -t <token>

# BM hosts connect directly
# Then route VM traffic through host's WireGuard tunnel
```

| Pros | Cons |
|------|------|
| Direct host-to-host connection | Architecture change |
| No NAT translation issues | VMs don't have individual identities |
| Simpler networking | Need to configure VM routing |

### Solution Comparison

| Solution | Complexity | Latency | Reliability | Firewall Changes |
|----------|------------|---------|-------------|------------------|
| Port Forwarding | Medium | Low | High | Yes |
| Relay | Low | High | High | No |
| WG on BM Host | Medium | Low | High | No |
| Hole Punching | Low | Low | Low (with Symmetric NAT) | No |

---

## Summary: Key Concepts

| Concept | What It Is | Why It Matters |
|---------|------------|----------------|
| **NAT** | Translates private IPs to public | Blocks unsolicited inbound |
| **Symmetric NAT** | Different external port per destination | Breaks hole punching |
| **STUN** | Discovers public IP:port | Can report wrong port with Symmetric NAT |
| **Hole Punching** | Both sides send simultaneously | Fails when ports mismatch |
| **conntrack** | Tracks connections in kernel | Shows [UNREPLIED] when traffic is one-way |
| **iptables FORWARD** | Controls forwarded packets | Must ACCEPT to allow traffic to VMs |
| **DNAT** | Rewrites destination address | Enables port forwarding |
| **WireGuard Handshake** | Establishes encrypted tunnel | Needs bidirectional UDP connectivity |

---

## Quick Reference: Debugging Commands

```bash
# Check NAT type
sudo apt install stun-client
stun stun.l.google.com:19302

# Check connection tracking
sudo conntrack -L | grep <remote-ip>

# Check for dropped packets
sudo iptables -L FORWARD -n -v | grep DROP

# Capture WireGuard traffic
sudo tcpdump -i eth0 udp port 51820

# Check WireGuard status
sudo wg show

# Check netclient networks
sudo netclient list

# Test UDP connectivity
nc -u -v <remote-ip> <port>
```
