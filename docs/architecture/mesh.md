# Chameleon Mesh Architecture v2 — ASPIRATIONAL DESIGN

> ⚠️ **This is a design proposal, NOT current architecture.** None of it
> is implemented. Drafted 2026-04-22; no work has started. The live
> topology is DE + NL only (see `infrastructure/topology.yaml`), the
> live component map is [`components.yaml`](components.yaml), and the
> live plan is [`../plan.yaml`](../plan.yaml). Keep this file for the
> thinking it captures (CockroachDB vs Postgres+CRDT, libp2p vs direct
> QUIC, Raft for atomic ops) — revisit if/when 20+ nodes is on the
> roadmap. The "Migration phases / TODAY" section below is from the
> original draft; its dates are not real.

**Scale target (if pursued):** 20+ nodes globally
**Status:** proposed, not started — not tracked by any `plan.yaml` phase

---

## Goals

1. **Decentralized by default.** Any node can serve any client. No primary/replica.
2. **Blast radius = 1 node.** Compromising a single node must not leak secrets or grant write access to peer data.
3. **Fast for client.** Client connects to geo-nearest node with <100ms auth latency.
4. **Fast for admin.** Admin actions (rotate keys, maintenance) propagate to all nodes in seconds.
5. **Scales to 20+ nodes without O(N²) complexity.**

---

## Design decisions (locked)

| Decision | Choice | Alternatives considered | Rationale |
|---|---|---|---|
| Database | CockroachDB (replaces per-node Postgres) | Postgres + CRDT layer, ScyllaDB, FoundationDB | Serializable SQL transactions, multi-region by design, automatic sharding, Postgres wire-compatible (minimal SQL rewrite) |
| Transport | libp2p (QUIC+TLS1.3, mTLS identity) | QUIC+mTLS direct, gRPC+mTLS | Built-in NAT traversal, pub/sub (gossipsub), peer discovery via Kademlia DHT, 20+ nodes makes DHT valuable |
| Identity | Ed25519 per-node | X.509 cert chain, shared bearer | Self-sovereign, fast, standard for libp2p |
| Consensus | hashicorp/raft for critical ops | CRDT-only, Paxos | UUID allocation + key rotation demand linearizability |
| User data replication | CockroachDB-native (not CRDT) | CRDT layer, manual sync | CDB already solves distributed consistency. Don't re-invent. |
| Server list | CockroachDB with per-node write constraint via row-level security | Single-writer CRDT | RLS enforces `node_id = current_node_id` on UPDATE. Peer node literally cannot UPDATE another node's row. |

### Why CockroachDB and not Postgres+CRDT

- At 20 nodes, manual CRDT sync becomes O(N²) bandwidth and logical complexity. CRDB does gossip + consensus internally.
- CRDB gives **serializable transactions across the cluster** — we get "reserve this UUID globally" for free.
- Postgres wire-compatible: most existing SQL ports with minimal rewrite (we use `pgx` already).
- Multi-region aware: can pin latency-sensitive data to primary region, replicate read-only elsewhere.
- Paid support available when we outgrow open-core.

### Why libp2p and not direct QUIC

- **Kademlia DHT** for peer discovery — new node joins mesh by knowing one peer. At 20+ nodes this matters (static peer lists become fragile).
- **GossipSub** for rumor propagation (node health, alerts).
- **NAT traversal** built-in (important if we add cheap consumer-ISP nodes).
- **Stream multiplexing** — single TCP/QUIC connection carries many logical streams.
- **Batteries for authenticated channels** — no DIY mTLS plumbing.

### Why Raft for allocation/rotation

- VPN UUID must be globally unique at allocation time (not eventually).
- Reality key rotation must be atomic — all nodes must switch simultaneously, not "eventually consistent".
- CockroachDB's internal Raft handles data, but for **application-level atomic events** (e.g. "rotate NL's reality keypair in 30 seconds") we need our own state machine.
- `hashicorp/raft` is battle-tested (Consul, Nomad, Vault), supports BoltDB backend (no extra deps).

---

## Node anatomy (new)

Each node runs:

1. **`chameleon`** (existing Go backend, refactored):
   - Mobile API, admin API, billing, Apple/FK integrations.
   - Connects to CockroachDB cluster (via local node or remote).
   - libp2p host on `:4001`, identity key in `/etc/chameleon/node.key` (Ed25519, chmod 600).
   - Raft node (peer list from CRDB `mesh_nodes` table).

2. **`chameleon-vpn`** (new binary):
   - Wraps sing-box with User API integration.
   - Subscribes to local Raft state for "active users on this node".
   - No direct DB access. Reads from sibling `chameleon` process over local Unix socket.

3. **CockroachDB** (separate container):
   - Joins regional cluster (3-5 nodes per region, replication factor 3).
   - For a 20-node global deploy: 3 regions (EU, US, APAC), each with CRDB cluster, cross-region async replication for non-critical tables.

### What node has vs. what leaks on compromise

| Asset | Stored on node? | If node compromised, attacker gets... |
|---|---|---|
| Node's own Ed25519 identity key | Yes | Ability to impersonate this specific node to mesh peers |
| Node's own Reality private key | Yes | MITM of traffic routed through **this** node only |
| CRDB read replica of user data | Yes | Read-only snapshot (but CRDB enforces role-based access; node role can be limited) |
| CRDB write access to *other* nodes' server rows | **No** (RLS blocks) | Cannot overwrite DE's reality key from NL |
| Admin JWT signing key | **No** (lives on control-flagged nodes only) | Cannot forge admin tokens |
| Peer nodes' Reality private keys | **No** | Cannot MITM traffic of other nodes |
| Peer nodes' provider credentials | **No** | Cannot access peer VPS hosting panels |

**Blast radius = traffic through the compromised node during the window before revocation.**

---

## Schema changes (CRDB)

### New tables

```sql
-- Replaces shared cluster.secret + vpn_servers.reality_private_key being writable by any peer.
CREATE TABLE mesh_nodes (
    node_id       UUID PRIMARY KEY,
    identity_pub  BYTES NOT NULL,              -- Ed25519 pubkey, 32 bytes
    role          STRING NOT NULL,             -- 'vpn' | 'control' | 'both'
    advertised_at JSONB NOT NULL,              -- { libp2p: "/ip4/x.x.x.x/udp/4001/quic-v1/p2p/..." }
    server_key    STRING UNIQUE,               -- which vpn_servers.key this node owns (null for pure control)
    revoked_at    TIMESTAMPTZ,                 -- non-null means revoked
    joined_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Row-level security on vpn_servers: a node can only write to its own row.
ALTER TABLE vpn_servers ADD COLUMN owner_node_id UUID REFERENCES mesh_nodes(node_id);
CREATE POLICY server_owner_write ON vpn_servers
    FOR UPDATE TO role_vpn_node
    USING (owner_node_id = current_setting('app.current_node_id')::UUID);

-- Raft log snapshot markers (we store FSM state in CRDB for durability beyond BoltDB).
CREATE TABLE raft_log (
    index     INT8 PRIMARY KEY,
    term      INT8 NOT NULL,
    data      BYTES NOT NULL,
    entry_ts  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE raft_snapshots (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    index     INT8 NOT NULL,
    term      INT8 NOT NULL,
    data      BYTES NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Removed tables / fields

- `vpn_servers.reality_private_key` → moved to node-local `/etc/chameleon/reality.key` (per-node secret, never replicated).
- `vpn_servers.provider_login`, `vpn_servers.provider_password` → moved to `/etc/chameleon/provider.env` (per-node secret).
- `cluster.secret` in config → removed entirely (replaced by Ed25519 identity).

---

## Protocol (libp2p)

Stream protocols:

```
/chameleon/mesh/1.0.0/sync        — anti-entropy state reconciliation
/chameleon/mesh/1.0.0/raft        — Raft RPC transport (wraps hashicorp/raft transport)
/chameleon/mesh/1.0.0/gossipsub   — gossipsub for rumors (node health, alerts)
/chameleon/mesh/1.0.0/health      — direct health query (admin panel use)
```

All streams are authenticated at libp2p layer (peer ID = hash of Ed25519 pubkey, verified on handshake). Additionally, every message payload is **signed with sender's identity key** for end-to-end auth even if one hop is malicious (relay scenarios).

---

## Client-facing changes

### Mobile API: geo-routing

- Client discovers nodes via `GET /api/mobile/nodes` on any node. Response includes libp2p multiaddrs AND direct HTTPS endpoints.
- Client picks nearest node (by measured TCP RTT, backend-provided hint, or GeoIP).
- Client's JWT is signed by its home node but verifiable by **any** node via public key lookup in `mesh_nodes.identity_pub`.
- Config fetch: client calls `/api/mobile/config` on any node → CRDB lookup → response includes server list with live status (gossipsub health data).

### Preflight removal

- Client no longer probes servers before connecting.
- Backend (any node) knows live status via gossipsub and returns sorted server list.
- Connect attempts top-1, 5s watchdog, fallback to top-2 automatically.

---

## Admin-facing changes

- Admin panel connects to any node.
- Read queries served locally (CRDB replica).
- Write queries (create user, extend subscription) go through CRDB leaseholder — automatic.
- Atomic ops (rotate reality key, revoke node) → Raft proposal → committed across cluster in <500ms.
- Live metrics stream: admin subscribes to gossipsub topic `mesh.health`, gets per-node CPU/RAM/active-users in real time.

---

## Migration phases

### Phase 0 — Close active CRITICAL leak (2-3 hours, TODAY)
Patch `SyncServer` wire format in current federated code. Remove `reality_private_key`, `provider_login`, `provider_password` from the marshaled JSON. This buys us safe runway while building mesh.

### Phase 1 — Foundation (week 1)
- CockroachDB cluster spin-up (3-node, on DE/NL/SPB).
- Data migration from Postgres → CRDB (keep Postgres as fallback for 1 week).
- Ed25519 identity infra: keygen on deploy, `/etc/chameleon/node.key`, CRDB `mesh_nodes` table.
- libp2p host scaffolding in `internal/mesh/`.
- Peer discovery: static bootstrap list + Kademlia DHT.

### Phase 2 — Consensus & secrets isolation (week 2)
- hashicorp/raft integrated.
- UUID allocation moved to Raft FSM.
- Reality keys moved to node-local storage, removed from DB.
- RLS on `vpn_servers` (per-node write constraint).
- Gossipsub for health/alerts.

### Phase 3 — Client smart routing (week 3, days 1-4)
- `/api/mobile/nodes` endpoint.
- iOS client: geo-nearest selection, preflight removed, watchdog-based fallback.
- Cross-node JWT verification.

### Phase 4 — Admin live view & key rotation UX (week 3, days 5-7)
- Admin SSE stream of mesh health.
- Admin action: rotate reality key (Raft proposal, atomic switchover).
- Admin action: revoke node (marks `revoked_at`, peers disconnect).

---

## Open questions

- **CRDB licensing:** using open-core (CCL license) fine for us? Paid version has extra features (CDC, change-data-capture) we may want later.
- **Bootstrap for brand new node:** how operator gets it into mesh. Proposal: `chameleon node init --join=<existing-peer-multiaddr> --invite-token=<signed-JWT-from-existing-admin>`. Invite token is one-shot, signed by an admin, contains future node's pubkey.
- **Backup strategy:** CRDB built-in `BACKUP` command to S3/R2. Encrypted backups via `encryption_passphrase` option.
- **Cost:** CRDB footprint vs. per-node Postgres. For 3-node small cluster: roughly same RAM. For 20+ nodes: CRDB wins (clients connect to nearest, not round-trip to DE).

---

## What does NOT change

- VLESS Reality as VPN protocol (it's already secure end-to-end).
- sing-box as data plane implementation.
- iOS/macOS client core (only server selection logic changes).
- Admin panel UI (backend changes, UI uses same API shape).
- Apple Sign-In, FreeKassa, StoreKit flows.
