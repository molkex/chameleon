// Package cluster provides peer-to-peer user synchronization between autonomous
// Chameleon VPN nodes. Each node has its own PostgreSQL, Redis, and sing-box.
// Cluster sync is an optional feature that replicates user data across nodes.
//
// Sync architecture:
//   - Real-time: Redis Pub/Sub — instant propagation of user changes
//   - Fallback: HTTP pull/push — periodic reconciliation (every 5 min)
//   - Conflict resolution: latest updated_at wins (handled by DB upsert)
//   - Users are identified by vpn_uuid (globally unique)
//
// All operations are graceful: if a peer is unreachable or Redis pub/sub fails,
// the syncer logs a warning and continues. No failure can affect local node operation.
package cluster

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// maxPushBatchSize limits the number of users sent in a single push request
// to avoid excessively large payloads.
const maxPushBatchSize = 500

// Syncer performs real-time (Redis Pub/Sub) and periodic (HTTP) user synchronization
// with cluster peers. It is safe for concurrent use.
type Syncer struct {
	db     *db.DB
	config config.ClusterConfig
	vpn    vpn.Engine
	logger *zap.Logger
	client *http.Client

	// Redis Pub/Sub components.
	publisher  *Publisher
	subscriber *Subscriber

	// lastSync tracks the last successful sync timestamp per peer (HTTP fallback).
	mu       sync.Mutex
	lastSync map[string]time.Time

	stopCh chan struct{}
	wg     sync.WaitGroup
}

// NewSyncer creates a cluster syncer. If cluster is disabled in config,
// Start() will be a no-op.
//
// The rdb parameter is used for Redis Pub/Sub. Pass nil to disable pub/sub
// (HTTP-only fallback mode).
func NewSyncer(database *db.DB, cfg config.ClusterConfig, engine vpn.Engine, rdb *redis.Client, logger *zap.Logger) *Syncer {
	s := &Syncer{
		db:     database,
		config: cfg,
		vpn:    engine,
		logger: logger.Named("cluster"),
		client: &http.Client{
			Timeout: 30 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
				MaxIdleConnsPerHost: 2,
				IdleConnTimeout:     90 * time.Second,
			},
		},
		lastSync: make(map[string]time.Time),
		stopCh:   make(chan struct{}),
	}

	// Initialize Redis Pub/Sub if Redis is available.
	if rdb != nil && cfg.Enabled {
		channel := cfg.PubSubChannel
		s.publisher = NewPublisher(rdb, cfg.NodeID, channel, logger)
		s.subscriber = NewSubscriber(rdb, cfg.NodeID, channel, database, engine, logger)
	}

	return s
}

// Publisher returns the cluster Publisher for broadcasting events.
// Returns nil if pub/sub is not configured.
func (s *Syncer) Publisher() *Publisher {
	return s.publisher
}

// Start begins the real-time subscriber and periodic reconciliation loop.
// It returns immediately. If clustering is disabled or there are no peers,
// this is a no-op.
func (s *Syncer) Start(ctx context.Context) {
	if !s.config.Enabled || len(s.config.Peers) == 0 {
		s.logger.Info("cluster sync disabled or no peers configured")
		return
	}

	s.logger.Info("starting cluster sync",
		zap.String("node_id", s.config.NodeID),
		zap.Int("peers", len(s.config.Peers)),
		zap.Duration("reconcile_interval", s.config.ReconcileInterval.Duration),
		zap.String("pubsub_channel", s.config.PubSubChannel),
	)

	// Start Redis Pub/Sub subscriber in background.
	if s.subscriber != nil {
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.subscriber.Start(ctx)
		}()
		s.logger.Info("redis pub/sub subscriber started")
	}

	// Start HTTP reconciliation loop (fallback).
	s.wg.Add(1)
	go s.reconcileLoop(ctx)
}

// Stop gracefully stops the sync loop and waits for it to finish.
func (s *Syncer) Stop() {
	close(s.stopCh)
	if s.subscriber != nil {
		s.subscriber.Stop()
	}
	s.wg.Wait()
	s.logger.Info("cluster sync stopped")
}

// reconcileLoop runs the periodic HTTP sync cycle (full reconciliation).
// This catches any events missed by Redis pub/sub.
func (s *Syncer) reconcileLoop(ctx context.Context) {
	defer s.wg.Done()

	// Run an initial sync immediately.
	s.syncOnce(ctx)

	ticker := time.NewTicker(s.config.ReconcileInterval.Duration)
	defer ticker.Stop()

	for {
		select {
		case <-s.stopCh:
			return
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.syncOnce(ctx)
		}
	}
}

// syncOnce performs one sync cycle with all peers.
// For each peer:
//  1. Pull: GET /api/cluster/pull?since=<timestamp> -- get users changed since last sync
//  2. Push: POST /api/cluster/push -- send our changed users
//  3. After any changes: reload VPN engine with merged user list
func (s *Syncer) syncOnce(ctx context.Context) {
	var changed bool

	for _, peer := range s.config.Peers {
		peerChanged, err := s.syncPeer(ctx, peer)
		if err != nil {
			s.logger.Warn("sync with peer failed",
				zap.String("peer_id", peer.ID),
				zap.String("peer_url", peer.URL),
				zap.Error(err),
			)
			continue
		}
		if peerChanged {
			changed = true
		}
	}

	// If any users were changed, reload the VPN engine.
	if changed {
		s.reloadVPN(ctx)
	}
}

// syncPeer performs pull + push with a single peer.
// Returns true if any local users were created or updated.
func (s *Syncer) syncPeer(ctx context.Context, peer config.PeerConfig) (bool, error) {
	s.mu.Lock()
	since := s.lastSync[peer.ID]
	s.mu.Unlock()

	// --- Pull ---
	pulled, err := s.pullFromPeer(ctx, peer, since)
	if err != nil {
		return false, fmt.Errorf("pull: %w", err)
	}

	// Upsert pulled users into local DB.
	var localChanged bool
	for i := range pulled {
		updated, err := s.db.UpsertUserByVPNUUID(ctx, &pulled[i])
		if err != nil {
			s.logger.Error("failed to upsert pulled user",
				zap.String("vpn_uuid", safeDeref(pulled[i].VPNUUID)),
				zap.Error(err),
			)
			continue
		}
		if updated {
			localChanged = true
		}
	}

	// --- Push ---
	ourUsers, err := s.db.UsersChangedSince(ctx, since)
	if err != nil {
		return localChanged, fmt.Errorf("query local changes: %w", err)
	}

	if len(ourUsers) > 0 {
		if err := s.pushToPeer(ctx, peer, ourUsers); err != nil {
			return localChanged, fmt.Errorf("push: %w", err)
		}
	}

	// Update last sync time.
	now := time.Now().UTC()
	s.mu.Lock()
	s.lastSync[peer.ID] = now
	s.mu.Unlock()

	if len(pulled) > 0 || len(ourUsers) > 0 {
		s.logger.Info("reconciliation cycle complete",
			zap.String("peer_id", peer.ID),
			zap.Int("pulled", len(pulled)),
			zap.Int("pushed", len(ourUsers)),
			zap.Bool("local_changed", localChanged),
		)
	}

	return localChanged, nil
}

// pullFromPeer requests changed users from a peer node.
func (s *Syncer) pullFromPeer(ctx context.Context, peer config.PeerConfig, since time.Time) ([]db.User, error) {
	url := fmt.Sprintf("%s/api/cluster/pull?since=%s", peer.URL, since.UTC().Format(time.RFC3339Nano))

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("X-Cluster-Node-ID", s.config.NodeID)

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("http request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("unexpected status %d: %s", resp.StatusCode, string(body))
	}

	var result PullResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	return syncUsersToDBUsers(result.Users), nil
}

// pushToPeer sends changed users to a peer node.
func (s *Syncer) pushToPeer(ctx context.Context, peer config.PeerConfig, users []db.User) error {
	syncUsers := dbUsersToSyncUsers(users)

	// Send in batches to avoid massive payloads.
	for i := 0; i < len(syncUsers); i += maxPushBatchSize {
		end := i + maxPushBatchSize
		if end > len(syncUsers) {
			end = len(syncUsers)
		}

		payload := PushRequest{
			NodeID: s.config.NodeID,
			Users:  syncUsers[i:end],
		}

		body, err := json.Marshal(payload)
		if err != nil {
			return fmt.Errorf("marshal push payload: %w", err)
		}

		url := fmt.Sprintf("%s/api/cluster/push", peer.URL)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("create request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Cluster-Node-ID", s.config.NodeID)

		resp, err := s.client.Do(req)
		if err != nil {
			return fmt.Errorf("http request: %w", err)
		}
		resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("unexpected status %d from peer %s", resp.StatusCode, peer.ID)
		}
	}

	return nil
}

// reloadVPN refreshes the VPN engine with the current active user list.
func (s *Syncer) reloadVPN(ctx context.Context) {
	if s.vpn == nil {
		return
	}

	users, err := s.db.ListActiveVPNUsers(ctx)
	if err != nil {
		s.logger.Error("failed to list active VPN users for reload", zap.Error(err))
		return
	}

	vpnUsers := make([]vpn.VPNUser, 0, len(users))
	for _, u := range users {
		if u.VPNUUID == nil || u.VPNUsername == nil {
			continue
		}
		vu := vpn.VPNUser{
			Username: *u.VPNUsername,
			UUID:     *u.VPNUUID,
		}
		if u.VPNShortID != nil {
			vu.ShortID = *u.VPNShortID
		}
		vpnUsers = append(vpnUsers, vu)
	}

	count, err := s.vpn.ReloadUsers(ctx, vpnUsers)
	if err != nil {
		s.logger.Error("failed to reload VPN users after sync", zap.Error(err))
		return
	}

	s.logger.Info("VPN users reloaded after sync", zap.Int("active_users", count))
}

// safeDeref returns the value of a string pointer or "<nil>" if nil.
func safeDeref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}
