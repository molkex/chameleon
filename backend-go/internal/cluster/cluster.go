// Package cluster provides peer-to-peer user synchronization between autonomous
// Chameleon VPN nodes. See sync.go for the main sync loop, pubsub.go for
// Redis Pub/Sub real-time sync, and routes.go for the internal HTTP API.
//
// Architecture:
//   - Each node is fully autonomous (own PostgreSQL + Redis + sing-box)
//   - Cluster sync is optional -- nodes work fine without it
//   - No "master" node -- all peers are equal
//   - Real-time sync via Redis Pub/Sub (primary)
//   - HTTP pull/push for periodic reconciliation (fallback every 5 min)
//   - Conflict resolution: latest updated_at wins
//   - Users identified by vpn_uuid (globally unique)
package cluster
