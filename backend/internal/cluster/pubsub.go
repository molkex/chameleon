// Package cluster — Redis Pub/Sub for real-time cluster synchronization.
//
// When a user is created, updated, or deleted on any node, the change is
// published to a Redis channel. All other nodes receive the event, upsert
// the user into their local DB, and reload the VPN engine.
//
// This is an optimistic, best-effort mechanism. If Redis pub/sub misses an
// event (network blip, reconnect), the periodic HTTP reconciliation (every 5 min)
// catches up.
package cluster

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// EventType defines the type of sync event.
type EventType string

const (
	EventUserCreated  EventType = "user.created"
	EventUserUpdated  EventType = "user.updated"
	EventUserDeleted  EventType = "user.deleted"
	EventConfigReload EventType = "config.reload"
)

// SyncEvent is the message published to Redis pub/sub.
type SyncEvent struct {
	Type      EventType `json:"type"`
	NodeID    string    `json:"node_id"`
	Timestamp time.Time `json:"timestamp"`
	User      *SyncUser `json:"user,omitempty"`
}

// Publisher publishes sync events to Redis.
type Publisher struct {
	redis   *redis.Client
	nodeID  string
	channel string
	logger  *zap.Logger
}

// NewPublisher creates a Publisher that sends events to the given Redis channel.
func NewPublisher(rdb *redis.Client, nodeID, channel string, logger *zap.Logger) *Publisher {
	return &Publisher{
		redis:   rdb,
		nodeID:  nodeID,
		channel: channel,
		logger:  logger.Named("cluster.publisher"),
	}
}

// Publish sends a SyncEvent to all subscribed nodes.
// Errors are logged but never returned to the caller — pub/sub is best-effort.
func (p *Publisher) Publish(ctx context.Context, event SyncEvent) error {
	event.NodeID = p.nodeID
	event.Timestamp = time.Now().UTC()

	data, err := json.Marshal(event)
	if err != nil {
		p.logger.Error("failed to marshal sync event", zap.Error(err))
		return err
	}

	if err := p.redis.Publish(ctx, p.channel, data).Err(); err != nil {
		p.logger.Error("failed to publish sync event",
			zap.String("type", string(event.Type)),
			zap.Error(err),
		)
		return err
	}

	p.logger.Debug("published sync event",
		zap.String("type", string(event.Type)),
	)
	return nil
}

// Subscriber listens for sync events from other nodes via Redis pub/sub.
type Subscriber struct {
	redis    *redis.Client
	nodeID   string
	channel  string
	db       *db.DB
	vpn      vpn.Engine
	logger   *zap.Logger
	stopCh   chan struct{}
	stopOnce sync.Once // Stop() is idempotent.
}

// NewSubscriber creates a Subscriber that listens on the given Redis channel.
func NewSubscriber(rdb *redis.Client, nodeID, channel string, database *db.DB, engine vpn.Engine, logger *zap.Logger) *Subscriber {
	return &Subscriber{
		redis:   rdb,
		nodeID:  nodeID,
		channel: channel,
		db:      database,
		vpn:     engine,
		logger:  logger.Named("cluster.subscriber"),
		stopCh:  make(chan struct{}),
	}
}

// Start begins listening for Redis pub/sub messages.
// It blocks until Stop() is called or the context is cancelled.
// On Redis disconnection it automatically reconnects (go-redis handles this).
func (s *Subscriber) Start(ctx context.Context) {
	s.logger.Info("starting pub/sub subscriber",
		zap.String("channel", s.channel),
		zap.String("node_id", s.nodeID),
	)

	pubsub := s.redis.Subscribe(ctx, s.channel)
	defer func() {
		if err := pubsub.Close(); err != nil {
			s.logger.Error("failed to close pub/sub", zap.Error(err))
		}
	}()

	ch := pubsub.Channel()

	for {
		select {
		case <-s.stopCh:
			s.logger.Info("pub/sub subscriber stopped")
			return
		case <-ctx.Done():
			s.logger.Info("pub/sub subscriber context cancelled")
			return
		case msg, ok := <-ch:
			if !ok {
				s.logger.Warn("pub/sub channel closed, stopping subscriber")
				return
			}
			s.handleMessage(ctx, msg)
		}
	}
}

// Stop signals the subscriber to stop listening. Idempotent.
func (s *Subscriber) Stop() {
	s.stopOnce.Do(func() {
		close(s.stopCh)
	})
}

// handleMessage parses and processes a single pub/sub message.
func (s *Subscriber) handleMessage(ctx context.Context, msg *redis.Message) {
	var event SyncEvent
	if err := json.Unmarshal([]byte(msg.Payload), &event); err != nil {
		s.logger.Error("failed to unmarshal sync event",
			zap.Error(err),
			zap.String("payload", msg.Payload),
		)
		return
	}

	// Ignore our own events.
	if event.NodeID == s.nodeID {
		return
	}

	s.logger.Debug("received sync event",
		zap.String("type", string(event.Type)),
		zap.String("from_node", event.NodeID),
	)

	s.handleEvent(ctx, event)
}

// handleEvent processes a received SyncEvent.
func (s *Subscriber) handleEvent(ctx context.Context, event SyncEvent) {
	switch event.Type {
	case EventUserCreated, EventUserUpdated:
		if event.User == nil {
			s.logger.Warn("received user event without user data",
				zap.String("type", string(event.Type)),
			)
			return
		}

		dbUsers := syncUsersToDBUsers([]SyncUser{*event.User})
		if len(dbUsers) == 0 {
			return
		}

		updated, err := s.db.UpsertUserByVPNUUID(ctx, &dbUsers[0])
		if err != nil {
			s.logger.Error("failed to upsert user from pub/sub event",
				zap.String("vpn_uuid", event.User.VPNUUID),
				zap.Error(err),
			)
			return
		}

		if updated {
			s.logger.Info("user upserted via pub/sub",
				zap.String("vpn_uuid", event.User.VPNUUID),
				zap.String("type", string(event.Type)),
			)
			s.reloadVPN(ctx)
		}

	case EventUserDeleted:
		if event.User == nil {
			return
		}
		// For delete events, we deactivate the user locally.
		deactivated := *event.User
		deactivated.IsActive = false
		dbUsers := syncUsersToDBUsers([]SyncUser{deactivated})
		if len(dbUsers) == 0 {
			return
		}

		updated, err := s.db.UpsertUserByVPNUUID(ctx, &dbUsers[0])
		if err != nil {
			s.logger.Error("failed to deactivate user from pub/sub event",
				zap.String("vpn_uuid", event.User.VPNUUID),
				zap.Error(err),
			)
			return
		}

		if updated {
			s.logger.Info("user deactivated via pub/sub",
				zap.String("vpn_uuid", event.User.VPNUUID),
			)
			s.reloadVPN(ctx)
		}

	case EventConfigReload:
		s.logger.Info("config reload requested via pub/sub",
			zap.String("from_node", event.NodeID),
		)
		s.reloadVPN(ctx)

	default:
		s.logger.Warn("unknown sync event type",
			zap.String("type", string(event.Type)),
		)
	}
}

// reloadVPN refreshes the VPN engine with the current active user list.
func (s *Subscriber) reloadVPN(ctx context.Context) {
	if err := ReloadVPNEngine(ctx, s.db, s.vpn, s.logger); err != nil {
		s.logger.Error("failed to reload VPN after pub/sub event", zap.Error(err))
	}
}
