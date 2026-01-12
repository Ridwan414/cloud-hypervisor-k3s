# Ikto WireGuard Mesh Connection Flow

This document explains the Ikto project - a NATS-based WireGuard mesh network builder, its configuration, and the complete connection flow.

## Overview

**Ikto** is a decentralized WireGuard mesh builder that uses NATS JetStream KV for peer discovery and coordination. It was created by [Valyent](https://github.com/valyentdev) as the networking foundation for [Ravel](https://github.com/valyentdev/ravel), their micro-VM orchestrator.

### Key Characteristics

- **Decentralized** - No central control plane; NATS cluster provides coordination
- **Automatic mesh management** - Peers auto-discovered via NATS key-value store
- **IPv6-first** - Uses `fd10::/16` addressing by default
- **Secure** - WireGuard encryption + NATS credential authentication
- **Written in Go** (v1.22.5)

---

## Configuration Reference

```json
{
  "name": "node1",
  "advertise_address": "203.0.113.10",
  "private_address": "fd10:2082:5bc1::",
  "subnet_prefix": 48,
  "mesh_cidr": "fd10::/16",
  "wg_dev_name": "wg-ikto",
  "wg_port": 51820,
  "private_key_path": "/etc/ikto/wg_private.key",
  "nats_creds": "/etc/ikto/nats.creds",
  "nats_url": "nats://nats-server:4222",
  "nats_kv": "ikto-mesh"
}
```

### Config Field Details

| Field | Purpose | How It's Used |
|-------|---------|---------------|
| **name** | Human-readable node identifier | Stored in NATS KV for identification; shown in `ikto info` |
| **advertise_address** | Public/reachable IP of this node | Other nodes use this to establish WireGuard connections to you |
| **private_address** | Your mesh IP (internal) | Assigned to WireGuard interface; unique identifier in the mesh |
| **subnet_prefix** | Bits allocated per node (e.g., 48) | Combined with private_address to form `AllowedIP` CIDR (e.g., `fd10:2082:5bc1::/48`) |
| **mesh_cidr** | The entire mesh network range | Validates that private_address falls within; sets WireGuard interface mask |
| **wg_dev_name** | WireGuard interface name | Linux network interface created (e.g., `wg-ikto`) |
| **wg_port** | UDP port for WireGuard | Other peers connect to `advertise_address:wg_port` |
| **private_key_path** | Path to WireGuard private key | Used to derive public key and configure WireGuard |
| **nats_creds** | NATS authentication credentials | Authenticates to NATS cluster |
| **nats_url** | NATS server address | Connection endpoint for peer discovery |
| **nats_kv** | NATS KV bucket name | Shared bucket where all peers register themselves |

---

## How Values Interact

### IP Addressing Example

```
mesh_cidr:        fd10::/16          (entire mesh: fd10:0000::/16 to fd10:ffff::/16)
private_address:  fd10:2082:5bc1::   (this node's address)
subnet_prefix:    48                 (each node gets a /48 subnet)

Result -> AllowedIP: fd10:2082:5bc1::/48
```

This means:
- The mesh can have up to 2^32 unique /48 subnets
- Each node "owns" a /48 range (even though it only uses one IP)
- WireGuard routes traffic for `fd10:2082:5bc1::/48` to this node

### Network Interface Setup

```
wg_dev_name: wg-ikto
private_address: fd10:2082:5bc1::
mesh_cidr: fd10::/16

Creates:
  Interface: wg-ikto
  Address: fd10:2082:5bc1::/16  (IP with mesh-wide routing)
```

---

## Complete Flow Diagrams

### Phase 1: Initialization (`ikto init`)

```
+------------------------------------------------------------------+
|                        ikto init                                  |
+------------------------------------------------------------------+
|                                                                   |
|  1. Parse mesh_cidr (default: fd10::/16)                         |
|                     |                                             |
|                     v                                             |
|  2. Parse subnet_prefix (default: 48)                            |
|                     |                                             |
|                     v                                             |
|  3. Generate random bits for positions 16-48                     |
|     +------------------------------------------+                  |
|     | fd10:0000:0000::                         | <- Base network  |
|     |      ^^^^:^^^^                           |                  |
|     | fd10:2082:5bc1::                         | <- Random bits   |
|     +------------------------------------------+                  |
|                     |                                             |
|                     v                                             |
|  4. Output config JSON with random private_address               |
|                                                                   |
+-------------------------------------------------------------------+
```

**Code path:** `pkg/commands/init.go:21-41` (`RandomSubnet` function)

---

### Phase 2: Agent Startup (`ikto agent -c config.json`)

```
+------------------------------------------------------------------------------+
|                           ikto agent startup                                  |
+------------------------------------------------------------------------------+
|                                                                               |
|  STEP 1: Config Validation (pkg/commands/config.go:27-68)                    |
|  +-----------------------------------------------------------------------+   |
|  | - Parse mesh_cidr -> net.IPNet                                        |   |
|  | - Parse advertise_address -> net.IP                                   |   |
|  | - Parse private_address -> net.IP                                     |   |
|  | - Verify: private_address in mesh_cidr  (FAIL if not)                 |   |
|  +-----------------------------------------------------------------------+   |
|                                    |                                          |
|                                    v                                          |
|  STEP 2: Read Private Key (pkg/ikto/ikto.go:55-63)                           |
|  +-----------------------------------------------------------------------+   |
|  | - Read file at private_key_path                                       |   |
|  | - Parse as WireGuard private key                                      |   |
|  | - Derive public key: publicKey = privateKey.PublicKey()               |   |
|  +-----------------------------------------------------------------------+   |
|                                    |                                          |
|                                    v                                          |
|  STEP 3: Build Self Peer (pkg/ikto/ikto.go:67-73)                            |
|  +-----------------------------------------------------------------------+   |
|  | self = Peer{                                                          |   |
|  |   Name:             "node1"                                           |   |
|  |   PublicKey:        <derived from private key>                        |   |
|  |   AdvertiseAddress: "203.0.113.10"                                    |   |
|  |   AllowedIP:        "fd10:2082:5bc1::/48"  (private_addr/prefix)      |   |
|  |   WGPort:           51820                                             |   |
|  | }                                                                     |   |
|  +-----------------------------------------------------------------------+   |
|                                    |                                          |
|                                    v                                          |
|  STEP 4: Create WireGuard Device (internal/network/wg_device.go)             |
|  +-----------------------------------------------------------------------+   |
|  | 4a. Ensure() - Create interface if missing, bring UP                  |   |
|  |     $ ip link add wg-ikto type wireguard                              |   |
|  |     $ ip link set wg-ikto up                                          |   |
|  |                                                                       |   |
|  | 4b. InitConfig() - Set private key and listen port                    |   |
|  |     $ wg set wg-ikto private-key <key> listen-port 51820              |   |
|  |                                                                       |   |
|  | 4c. SetAddr() - Assign mesh IP to interface                           |   |
|  |     $ ip addr add fd10:2082:5bc1::/16 dev wg-ikto                     |   |
|  |     (Uses mesh_cidr mask so all mesh traffic routes through wg)       |   |
|  +-----------------------------------------------------------------------+   |
|                                    |                                          |
|                                    v                                          |
|  STEP 5: Connect to NATS (pkg/ikto/ikto.go:102-115)                          |
|  +-----------------------------------------------------------------------+   |
|  | - Connect to nats_url with nats_creds                                 |   |
|  | - Get JetStream client                                                |   |
|  | - Get KV bucket reference (nats_kv: "ikto-mesh")                      |   |
|  +-----------------------------------------------------------------------+   |
|                                    |                                          |
|                                    v                                          |
|  STEP 6: Setup State Callbacks (pkg/ikto/ikto.go:119-146)                    |
|  +-----------------------------------------------------------------------+   |
|  | OnInitPeers:  -> wg.ReplacePeers(all_existing_peers)                  |   |
|  | OnPeerPut:    -> wg.AddPeer(new_peer)                                 |   |
|  | OnPeerDelete: -> wg.RemovePeer(removed_peer)                          |   |
|  +-----------------------------------------------------------------------+   |
|                                                                               |
+-------------------------------------------------------------------------------+
```

---

### Phase 3: Self Registration (`Start()` -> `init()`)

```
+------------------------------------------------------------------------------+
|                        Self Registration Flow                                 |
|                     (pkg/ikto/ikto.go:160-183)                               |
+------------------------------------------------------------------------------+
|                                                                               |
|  KV Key = "peers." + base64("fd10:2082:5bc1::/48")                           |
|         = "peers.ZmQxMDoyMDgyOjViYzE6Oi80OA=="                                |
|                                                                               |
|  +-----------------------------------------------------------------------+   |
|  |              store.GetPeer(AllowedIP)                                 |   |
|  +-----------------------------------------------------------------------+   |
|                           |                                                   |
|           +---------------+---------------+                                   |
|           |               |               |                                   |
|           v               v               v                                   |
|    +----------+    +----------+    +--------------+                           |
|    | Not Found|    |  Found   |    |    Found     |                           |
|    |          |    | Same Key |    | Different Key|                           |
|    +----+-----+    +----+-----+    +------+-------+                           |
|         |               |                 |                                   |
|         v               v                 v                                   |
|  +------------+  +------------+    +-----------------+                        |
|  |CreatePeer()|  |UpdatePeer()|    | FAIL: Address   |                        |
|  | Atomic     |  | Optimistic |    | Already In Use  |                        |
|  | Create     |  | Lock Update|    |                 |                        |
|  +-----+------+  +-----+------+    +-----------------+                        |
|        |               |                                                      |
|        +-------+-------+                                                      |
|                |                                                              |
|                v                                                              |
|  +-----------------------------------------------------------------------+   |
|  |  KV Store now contains:                                               |   |
|  |  "peers.ZmQxMD..." = {                                                |   |
|  |    "name": "node1",                                                   |   |
|  |    "public_key": "abc123...",                                         |   |
|  |    "advertise_address": "203.0.113.10",                               |   |
|  |    "allowed_ip": "fd10:2082:5bc1::/48",                               |   |
|  |    "wg_port": 51820                                                   |   |
|  |  }                                                                    |   |
|  +-----------------------------------------------------------------------+   |
|                                                                               |
+-------------------------------------------------------------------------------+
```

---

### Phase 4: Peer Discovery & Sync (`state.Start()`)

```
+------------------------------------------------------------------------------+
|                         Peer Synchronization                                  |
|                    (internal/state/state.go)                                 |
+------------------------------------------------------------------------------+
|                                                                               |
|  INITIALIZATION PHASE (state.go:72-96)                                       |
|  +-----------------------------------------------------------------------+   |
|  | kv.Watch("peers.*") -> Returns watcher                                |   |
|  |                                                                       |   |
|  | for entry := range watcher.Updates() {                                |   |
|  |   if entry == nil { break }  // End of existing entries               |   |
|  |   if entry.PublicKey == self.PublicKey { continue } // Skip self      |   |
|  |   peers[entry.Key()] = parsePeer(entry.Value())                       |   |
|  | }                                                                     |   |
|  |                                                                       |   |
|  | OnInitPeers(peers) -> wg.ReplacePeers(all_peers)                      |   |
|  +-----------------------------------------------------------------------+   |
|                                    |                                          |
|                                    v                                          |
|  CONTINUOUS SYNC PHASE (state.go:98-127)                                     |
|  +-----------------------------------------------------------------------+   |
|  | go func() {                                                           |   |
|  |   for {                                                               |   |
|  |     select {                                                          |   |
|  |     case <-stop: return                                               |   |
|  |     case entry := <-watcher.Updates():                                |   |
|  |       switch entry.Operation() {                                      |   |
|  |       case PUT:    onPeerPut(key, peer)                               |   |
|  |       case DELETE: onPeerDelete(key)                                  |   |
|  |       case PURGE:  onPeerDelete(key)                                  |   |
|  |       }                                                               |   |
|  |     }                                                                 |   |
|  |   }                                                                   |   |
|  | }()                                                                   |   |
|  +-----------------------------------------------------------------------+   |
|                                                                               |
+-------------------------------------------------------------------------------+
```

---

### Phase 5: WireGuard Configuration Updates

```
+------------------------------------------------------------------------------+
|                     WireGuard Peer Configuration                              |
|                   (internal/network/wg_device.go)                            |
+------------------------------------------------------------------------------+
|                                                                               |
|  When OnPeerPut(peer) is called:                                             |
|  +-----------------------------------------------------------------------+   |
|  | peer.WGPeerConfig() returns:                                          |   |
|  | {                                                                     |   |
|  |   PublicKey:  peer.PublicKey,                                         |   |
|  |   Endpoint:   peer.AdvertiseAddress:peer.WGPort,                      |   |
|  |   AllowedIPs: [peer.AllowedIP],  // e.g., fd10:aaaa:bbbb::/48         |   |
|  | }                                                                     |   |
|  +-----------------------------------------------------------------------+   |
|                                    |                                          |
|                                    v                                          |
|  +-----------------------------------------------------------------------+   |
|  | wg.ConfigureDevice("wg-ikto", Config{Peers: [peerConfig]})            |   |
|  |                                                                       |   |
|  | Equivalent to:                                                        |   |
|  | $ wg set wg-ikto peer <pubkey> \                                      |   |
|  |     endpoint 203.0.113.20:51820 \                                     |   |
|  |     allowed-ips fd10:aaaa:bbbb::/48                                   |   |
|  +-----------------------------------------------------------------------+   |
|                                                                               |
+-------------------------------------------------------------------------------+
```

---

## Complete Multi-Node Architecture

```
+-------------------------------------------------------------------------------------+
|                              NATS JetStream KV                                       |
|                            Bucket: "ikto-mesh"                                       |
|  +---------------------------------------------------------------------------------+ |
|  | peers.ZmQxMD...== -> {"name":"node1","public_key":"abc...","allowed_ip":"..."}  | |
|  | peers.ZmQxME...== -> {"name":"node2","public_key":"def...","allowed_ip":"..."}  | |
|  | peers.ZmQxMF...== -> {"name":"node3","public_key":"ghi...","allowed_ip":"..."}  | |
|  +---------------------------------------------------------------------------------+ |
+-------------------------------------------------------------------------------------+
        ^ Watch          ^ Watch          ^ Watch
        | Create         | Create         | Create
        |                |                |
+-------+-------+ +------+--------+ +-----+---------+
|    Node 1     | |    Node 2     | |    Node 3     |
|               | |               | |               |
| advertise:    | | advertise:    | | advertise:    |
| 203.0.113.10  | | 203.0.113.20  | | 203.0.113.30  |
|               | |               | |               |
| private:      | | private:      | | private:      |
| fd10:1111::/48| | fd10:2222::/48| | fd10:3333::/48|
|               | |               | |               |
| +-----------+ | | +-----------+ | | +-----------+ |
| |  wg-ikto  | | | |  wg-ikto  | | | |  wg-ikto  | |
| | :51820    |<+-+>| :51820    |<+-+>| :51820    | |
| +-----------+ | | +-----------+ | | +-----------+ |
+---------------+ +---------------+ +---------------+
```

### WireGuard Config on Node 1

```
[Interface]
PrivateKey = <node1_private_key>
ListenPort = 51820
Address = fd10:1111::/16

[Peer]  # Node 2
PublicKey = def...
Endpoint = 203.0.113.20:51820
AllowedIPs = fd10:2222::/48

[Peer]  # Node 3
PublicKey = ghi...
Endpoint = 203.0.113.30:51820
AllowedIPs = fd10:3333::/48
```

---

## Event Timeline: New Node Joins

```
Time    Event
-----   ----------------------------------------------------------------------

T0      Node 3 starts: ikto agent -c config.json

T1      Node 3 creates WireGuard interface wg-ikto
        $ ip link add wg-ikto type wireguard
        $ ip addr add fd10:3333::/16 dev wg-ikto

T2      Node 3 connects to NATS, registers self:
        KV.Create("peers.ZmQxMF...", {node3_peer_json})

T3      Node 3 watches "peers.*", receives existing entries:
        - peers.ZmQxMD... (node1)
        - peers.ZmQxME... (node2)
        -> OnInitPeers() -> wg.ReplacePeers([node1, node2])

T4      Node 1 & Node 2 receive watch notification:
        "peers.ZmQxMF..." PUT event
        -> OnPeerPut(node3) -> wg.AddPeer(node3)

T5      Full mesh established:
        - Node 1 can ping fd10:3333:: (node3)
        - Node 2 can ping fd10:3333:: (node3)
        - Node 3 can ping fd10:1111:: (node1)
        - Node 3 can ping fd10:2222:: (node2)
```

---

## IPAM (IP Address Management) Strategy

Ikto uses a distributed IPAM mechanism:

1. **Random Allocation**: `ikto init` generates random IPv6 within mesh subnet
2. **IP Registration**: Each node registers its IP as a NATS KV key: `peers.{base64_encoded_IP}`
3. **Conflict Detection**:
   - On startup, check if IP key exists
   - If exists and public key differs -> conflict -> fail
   - If same peer -> update existing entry
   - If doesn't exist -> try atomic create with optimistic locking
4. **Guarantee**: NATS JetStream's optimistic locking ensures duplicate IPs never occur
5. **Design Pattern**: Works best with large IP pool relative to node count

---

## Project Structure

```
ikto/
├── main.go                    # Entry point
├── pkg/
│   ├── commands/              # CLI commands (agent, init, info)
│   │   ├── root.go            # Root command aggregator
│   │   ├── agent.go           # Main agent startup command
│   │   ├── init.go            # Configuration initialization
│   │   ├── info.go            # Node information query via gRPC
│   │   └── config.go          # Configuration validation & defaults
│   ├── ikto/ikto.go           # Core mesh management (~350 lines)
│   ├── types/                 # Peer and PublicKey data models
│   │   ├── peer.go            # Peer struct and WireGuard config conversion
│   │   └── public_key.go      # WireGuard public key wrapper
│   ├── server/                # gRPC admin API
│   │   └── server.go          # Admin service exposing node/peer info
│   └── proto/                 # Protocol buffer definitions
│       ├── api.proto          # Service and message definitions
│       ├── api.pb.go          # Generated Go code
│       └── api_grpc.pb.go     # Generated gRPC service code
└── internal/
    ├── network/               # WireGuard device management
    │   ├── wg_device.go       # WireGuard device creation, config, peer management
    │   └── ip.go              # Random subnet generation utilities
    └── state/                 # Peer state synchronization
        ├── state.go           # Real-time peer sync with KV watcher
        └── store.go           # Persistent peer storage in NATS KV
```

---

## Key Dependencies

| Dependency | Purpose |
|------------|---------|
| `github.com/nats-io/nats.go` | NATS client library and JetStream API |
| `github.com/spf13/cobra` | CLI framework for command parsing |
| `golang.zx2c4.com/wireguard/wgctrl` | WireGuard device control |
| `github.com/vishvananda/netlink` | Linux network interface management |
| `google.golang.org/grpc` | gRPC admin API server |
| `google.golang.org/protobuf` | Protocol buffers serialization |

---

## Quick Start

### Prerequisites
- NATS server/cluster running with JetStream enabled
- WireGuard installed on each node

### Step-by-Step Setup

**1. Set up NATS server** (on one machine or cluster):
```bash
# Simple single-node setup
nats-server -js
```

**2. Generate WireGuard keys** (on each node):
```bash
wg genkey > /etc/ikto/wg_private.key
chmod 600 /etc/ikto/wg_private.key
```

**3. Initialize config** (on each node):
```bash
ikto init > /etc/ikto/config.json
```

**4. Edit config** with your values:
```json
{
  "name": "node1",
  "advertise_address": "203.0.113.10",
  "private_address": "fd10:2082:5bc1::",
  "subnet_prefix": 48,
  "mesh_cidr": "fd10::/16",
  "wg_dev_name": "wg-ikto",
  "wg_port": 51820,
  "private_key_path": "/etc/ikto/wg_private.key",
  "nats_creds": "/etc/ikto/nats.creds",
  "nats_url": "nats://your-nats-server:4222",
  "nats_kv": "ikto-mesh"
}
```

**5. Start the agent** (on each node):
```bash
ikto agent -c /etc/ikto/config.json
```

**6. Verify connectivity**:
```bash
# Check mesh status
ikto info

# Ping another node on the mesh
ping fd10:xxxx:yyyy::   # Another node's mesh IP
```

---

## Summary Table

| Config Field | What Happens When Set |
|--------------|----------------------|
| `private_address` | Becomes your unique mesh IP; stored as KV key; assigned to WireGuard interface |
| `subnet_prefix` | Combined with private_address to form AllowedIP CIDR that other peers route to you |
| `mesh_cidr` | Validates private_address; sets WireGuard interface mask for mesh-wide routing |
| `advertise_address` | Shared with peers so they know how to reach you externally |
| `wg_port` | Peers connect to `advertise_address:wg_port` for WireGuard tunnels |
| `nats_kv` | All nodes must use same bucket name to discover each other |

---

## Architecture Summary

The elegance of Ikto is that **NATS KV becomes both the service discovery mechanism and the distributed lock** for IP allocation, while **WireGuard handles all encrypted data plane traffic**.

```
Control Plane: NATS JetStream KV
  - Peer discovery
  - IP allocation with optimistic locking
  - Real-time state synchronization

Data Plane: WireGuard
  - Encrypted peer-to-peer tunnels
  - Kernel-level routing
  - High-performance networking
```
