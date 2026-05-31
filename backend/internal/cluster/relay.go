// Relay user synchronisation: pushes the active VPN user list to every
// remote relay node's sing-box User API. The chameleon backend doesn't run
// on relay boxes (they're resource-constrained RU entry points), so the
// backend processes on the exit nodes are responsible for keeping relay
// inbound user lists in sync with the authoritative DB.
//
// Topology:
//   chameleon backend (NL)
//   ├─ local sing-box (127.0.0.1:15380)         ← SingboxEngine.userAPI
//   ├─ remote relay sing-box (e.g. MSK:15380)   ← RelayUserSyncer (relay inbounds)
//   └─ remote exit  sing-box (e.g. GRA:15380)   ← RelayUserSyncer (Reality inbound)
//
// Why both DE and NL run this syncer:
//   Bulk PUT is idempotent; either backend alone is sufficient, but running
//   on both gives free redundancy. If one side is down, the other keeps
//   relays up to date.
//
// Consistency model:
//   - Event-driven: invoked from ReloadVPNEngine after every user mutation
//     → propagation in <1 s on healthy networks
//   - Periodic safety net: Start() runs PushAll every N seconds (default
//     30s) to recover from transient failures or missed events
//
// Failure modes are non-fatal — a relay being unreachable logs a warning
// and doesn't affect local sing-box reload or cluster peer sync.
package cluster

import (
	"context"
	"sync"
	"time"

	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// relaySyncDB is the narrow DB surface RelayUserSyncer needs. The concrete
// *db.DB satisfies it; tests provide a fake to exercise PushAll without a live
// Postgres.
type relaySyncDB interface {
	ListActiveRelayServers(ctx context.Context) ([]db.VPNServer, error)
	ListActiveRemoteExitServers(ctx context.Context) ([]db.VPNServer, error)
	ListActiveRelayExitPeers(ctx context.Context) ([]db.RelayExitPeer, error)
	ListActiveVPNUsers(ctx context.Context) ([]db.User, error)
}

// RelayUserSyncer pushes the active VPN user list to remote relay nodes and
// remote exit nodes (off-box sing-box instances) via the sing-box User API.
// Safe for concurrent use.
type RelayUserSyncer struct {
	db      relaySyncDB
	secrets map[string]string // relay/exit server key -> Bearer secret
	logger  *zap.Logger

	// Timeout for a single per-inbound PUT request. Relay User API is LAN-ish
	// from an exit's POV (server-to-server, no CF throttling), so 10s is
	// generous; this just bounds the failure case when a relay is hard-down.
	pushTimeout time.Duration

	stopCh   chan struct{}
	stopOnce sync.Once
	wg       sync.WaitGroup
}

// NewRelayUserSyncer creates a syncer. `secrets` maps each relay server key
// (e.g. "msk") to its User API Bearer token. Relays present in DB but absent
// from `secrets` are logged and skipped (misconfigured — don't crash).
//
// If `secrets` is nil or empty, the syncer is effectively a no-op: PushAll
// returns nil without touching any relay.
func NewRelayUserSyncer(database *db.DB, secrets map[string]string, logger *zap.Logger) *RelayUserSyncer {
	return &RelayUserSyncer{
		db:          database,
		secrets:     secrets,
		logger:      logger.Named("relay-sync"),
		pushTimeout: 10 * time.Second,
		stopCh:      make(chan struct{}),
	}
}

// Start launches the periodic reconciliation loop. Returns immediately.
// Calling Start with a zero-or-negative interval disables the periodic
// loop — event-driven pushes via PushAll still work.
func (r *RelayUserSyncer) Start(ctx context.Context, interval time.Duration) {
	if r == nil || len(r.secrets) == 0 {
		return
	}
	if interval <= 0 {
		r.logger.Info("relay sync: periodic loop disabled (interval <= 0), event-driven only")
		return
	}

	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		// Initial reconcile on startup so a fresh backend boot converges
		// relay state without waiting for the first ticker or user event.
		if err := r.PushAll(ctx); err != nil {
			r.logger.Warn("relay sync: initial push failed", zap.Error(err))
		}

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-r.stopCh:
				return
			case <-ticker.C:
				if err := r.PushAll(ctx); err != nil {
					r.logger.Warn("relay sync: periodic push failed", zap.Error(err))
				}
			}
		}
	}()
	r.logger.Info("relay sync: periodic loop started", zap.Duration("interval", interval))
}

// Stop signals the periodic loop to exit and waits for it.
// Idempotent — safe to call multiple times.
func (r *RelayUserSyncer) Stop() {
	if r == nil {
		return
	}
	r.stopOnce.Do(func() {
		close(r.stopCh)
		r.wg.Wait()
	})
}

// PushAll reconciles every active relay's inbound user list against the DB.
// For each (relay, inbound) it does a bulk PUT of the current active users.
// Failures are logged but do not short-circuit — every relay gets a
// best-effort attempt.
//
// Safe to call concurrently (inner HTTP calls are independent).
func (r *RelayUserSyncer) PushAll(ctx context.Context) error {
	if r == nil || len(r.secrets) == 0 {
		return nil
	}

	relays, err := r.db.ListActiveRelayServers(ctx)
	if err != nil {
		return err
	}
	exits, err := r.db.ListActiveRemoteExitServers(ctx)
	if err != nil {
		return err
	}
	// Nothing to sync to — neither remote relays nor remote exit nodes are
	// configured. Skip the user query entirely (the co-located exit manages
	// its own users via the local SingboxEngine).
	if len(relays) == 0 && len(exits) == 0 {
		return nil
	}

	peers, err := r.db.ListActiveRelayExitPeers(ctx)
	if err != nil {
		return err
	}

	users, err := r.db.ListActiveVPNUsers(ctx)
	if err != nil {
		return err
	}
	vpnUsers := DBUsersToVPNUsers(users)

	// Index peers by relay key to avoid O(N×M) lookups.
	peersByRelay := make(map[string][]db.RelayExitPeer, len(relays))
	for _, p := range peers {
		peersByRelay[p.RelayServerKey] = append(peersByRelay[p.RelayServerKey], p)
	}

	for _, relay := range relays {
		secret := r.secrets[relay.Key]
		if secret == "" {
			r.logger.Warn("relay sync: no secret configured, skipping",
				zap.String("relay", relay.Key))
			continue
		}
		if relay.UserAPIURL == nil || *relay.UserAPIURL == "" {
			r.logger.Warn("relay sync: no user_api_url in DB, skipping",
				zap.String("relay", relay.Key))
			continue
		}

		relayPeers := peersByRelay[relay.Key]
		if len(relayPeers) == 0 {
			// Relay is active but has no active exit peers — nothing to push.
			continue
		}

		for _, p := range relayPeers {
			if err := r.pushToInbound(ctx, *relay.UserAPIURL, secret, p.RelayInboundTag, vpnUsers); err != nil {
				r.logger.Warn("relay sync: push failed",
					zap.String("relay", relay.Key),
					zap.String("inbound", p.RelayInboundTag),
					zap.Int("users", len(vpnUsers)),
					zap.Error(err))
				continue
			}
			r.logger.Debug("relay sync: pushed",
				zap.String("relay", relay.Key),
				zap.String("inbound", p.RelayInboundTag),
				zap.Int("users", len(vpnUsers)))
		}
	}

	// Remote exit nodes (e.g. GRA France) whose sing-box runs off-box: keep
	// their VLESS Reality inbound user list in sync as well. Only the Reality
	// inbound is User-API-managed (Hysteria2 users are config-baked), so we
	// push the active set to InboundTagVLESS. The co-located exit (NL) has a
	// NULL user_api_url and is excluded by the query — it never targets itself.
	for _, exit := range exits {
		secret := r.secrets[exit.Key]
		if secret == "" {
			r.logger.Warn("relay sync: no secret configured for remote exit, skipping",
				zap.String("exit", exit.Key))
			continue
		}
		if exit.UserAPIURL == nil || *exit.UserAPIURL == "" {
			continue
		}
		if err := r.pushToInbound(ctx, *exit.UserAPIURL, secret, vpn.InboundTagVLESS, vpnUsers); err != nil {
			r.logger.Warn("relay sync: remote exit push failed",
				zap.String("exit", exit.Key),
				zap.String("inbound", vpn.InboundTagVLESS),
				zap.Int("users", len(vpnUsers)),
				zap.Error(err))
			continue
		}
		r.logger.Debug("relay sync: pushed to remote exit",
			zap.String("exit", exit.Key),
			zap.String("inbound", vpn.InboundTagVLESS),
			zap.Int("users", len(vpnUsers)))
	}

	return nil
}

// pushToInbound does a single bulk replace against one relay inbound.
// Encapsulates the per-request timeout so one slow relay doesn't block
// the caller's context.
func (r *RelayUserSyncer) pushToInbound(ctx context.Context, baseURL, secret, inboundTag string, users []vpn.VPNUser) error {
	pushCtx, cancel := context.WithTimeout(ctx, r.pushTimeout)
	defer cancel()

	client := vpn.NewUserAPIClientFromURL(baseURL, secret, inboundTag)
	return client.ReplaceUsers(pushCtx, users)
}
