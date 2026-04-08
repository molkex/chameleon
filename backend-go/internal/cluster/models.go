package cluster

import (
	"time"

	"github.com/chameleonvpn/chameleon/internal/db"
)

// SyncUser is the wire format for user data exchanged between cluster peers.
// It contains only the fields relevant for VPN synchronization.
// Identified by VPNuuid (globally unique across all nodes).
type SyncUser struct {
	VPNUUID            string     `json:"vpn_uuid"`
	VPNUsername         string     `json:"vpn_username"`
	VPNShortID         string     `json:"vpn_short_id,omitempty"`
	IsActive           bool       `json:"is_active"`
	SubscriptionExpiry *time.Time `json:"subscription_expiry,omitempty"`
	CurrentPlan        *string    `json:"current_plan,omitempty"`
	CumulativeTraffic  int64      `json:"cumulative_traffic"`
	DeviceLimit        *int       `json:"device_limit,omitempty"`
	TelegramID         *int64     `json:"telegram_id,omitempty"`
	Username           *string    `json:"username,omitempty"`
	FullName           *string    `json:"full_name,omitempty"`
	AuthProvider       *string    `json:"auth_provider,omitempty"`
	AppleID            *string    `json:"apple_id,omitempty"`
	DeviceID           *string    `json:"device_id,omitempty"`
	PhoneNumber        *string    `json:"phone_number,omitempty"`
	GoogleID           *string    `json:"google_id,omitempty"`
	SubscriptionToken  *string    `json:"subscription_token,omitempty"`
	ActivationCode     *string    `json:"activation_code,omitempty"`
	CreatedAt          time.Time  `json:"created_at"`
	UpdatedAt          time.Time  `json:"updated_at"`
}

// PullResponse is returned by GET /api/cluster/pull.
type PullResponse struct {
	NodeID string     `json:"node_id"`
	Users  []SyncUser `json:"users"`
}

// PushRequest is sent to POST /api/cluster/push.
type PushRequest struct {
	NodeID string     `json:"node_id"`
	Users  []SyncUser `json:"users"`
}

// PushResponse is returned by POST /api/cluster/push.
type PushResponse struct {
	Received int `json:"received"`
	Applied  int `json:"applied"`
}

// dbUsersToSyncUsers converts a slice of db.User to SyncUser wire format.
func dbUsersToSyncUsers(users []db.User) []SyncUser {
	result := make([]SyncUser, 0, len(users))
	for _, u := range users {
		if u.VPNUUID == nil || u.VPNUsername == nil {
			continue
		}
		su := SyncUser{
			VPNUUID:            *u.VPNUUID,
			VPNUsername:         *u.VPNUsername,
			IsActive:           u.IsActive,
			SubscriptionExpiry: u.SubscriptionExpiry,
			CurrentPlan:        u.CurrentPlan,
			CumulativeTraffic:  u.CumulativeTraffic,
			DeviceLimit:        u.DeviceLimit,
			TelegramID:         u.TelegramID,
			Username:           u.Username,
			FullName:           u.FullName,
			AuthProvider:       u.AuthProvider,
			AppleID:            u.AppleID,
			DeviceID:           u.DeviceID,
			PhoneNumber:        u.PhoneNumber,
			GoogleID:           u.GoogleID,
			SubscriptionToken:  u.SubscriptionToken,
			ActivationCode:     u.ActivationCode,
			CreatedAt:          u.CreatedAt,
			UpdatedAt:          u.UpdatedAt,
		}
		if u.VPNShortID != nil {
			su.VPNShortID = *u.VPNShortID
		}
		result = append(result, su)
	}
	return result
}

// syncUsersToDBUsers converts a slice of SyncUser wire format to db.User.
func syncUsersToDBUsers(syncUsers []SyncUser) []db.User {
	result := make([]db.User, 0, len(syncUsers))
	for _, su := range syncUsers {
		u := db.User{
			VPNUUID:            strPtr(su.VPNUUID),
			VPNUsername:         strPtr(su.VPNUsername),
			IsActive:           su.IsActive,
			SubscriptionExpiry: su.SubscriptionExpiry,
			CurrentPlan:        su.CurrentPlan,
			CumulativeTraffic:  su.CumulativeTraffic,
			DeviceLimit:        su.DeviceLimit,
			TelegramID:         su.TelegramID,
			Username:           su.Username,
			FullName:           su.FullName,
			AuthProvider:       su.AuthProvider,
			AppleID:            su.AppleID,
			DeviceID:           su.DeviceID,
			PhoneNumber:        su.PhoneNumber,
			GoogleID:           su.GoogleID,
			SubscriptionToken:  su.SubscriptionToken,
			ActivationCode:     su.ActivationCode,
			CreatedAt:          su.CreatedAt,
			UpdatedAt:          su.UpdatedAt,
		}
		if su.VPNShortID != "" {
			u.VPNShortID = strPtr(su.VPNShortID)
		}
		result = append(result, u)
	}
	return result
}

// strPtr returns a pointer to a string value.
func strPtr(s string) *string {
	return &s
}
