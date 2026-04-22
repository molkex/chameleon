package db

import "time"

// User represents a VPN user (maps to "users" table).
// Fields match the PostgreSQL schema exactly, including all migrations through 009.
type User struct {
	ID                     int64      `db:"id"                       json:"id"`
	TelegramID             *int64     `db:"telegram_id"              json:"telegram_id,omitempty"`
	Username               *string    `db:"username"                 json:"username,omitempty"`
	FullName               *string    `db:"full_name"                json:"full_name,omitempty"`
	IsActive               bool       `db:"is_active"                json:"is_active"`
	SubscriptionExpiry     *time.Time `db:"subscription_expiry"      json:"subscription_expiry,omitempty"`
	VPNUsername            *string    `db:"vpn_username"             json:"vpn_username,omitempty"`
	VPNUUID                *string    `db:"vpn_uuid"                 json:"vpn_uuid,omitempty"`
	VPNShortID             *string    `db:"vpn_short_id"             json:"vpn_short_id,omitempty"`
	AuthProvider           *string    `db:"auth_provider"            json:"auth_provider,omitempty"`
	AppleID                *string    `db:"apple_id"                 json:"apple_id,omitempty"`
	DeviceID               *string    `db:"device_id"                json:"device_id,omitempty"`
	OriginalTransactionID  *string    `db:"original_transaction_id"  json:"original_transaction_id,omitempty"`
	AppStoreProductID      *string    `db:"app_store_product_id"     json:"app_store_product_id,omitempty"`
	AdSource               *string    `db:"ad_source"                json:"ad_source,omitempty"`
	CumulativeTraffic      int64      `db:"cumulative_traffic"       json:"cumulative_traffic"`
	DeviceLimit            *int       `db:"device_limit"             json:"device_limit,omitempty"`
	BotBlockedAt           *time.Time `db:"bot_blocked_at"           json:"bot_blocked_at,omitempty"`
	PhoneNumber            *string    `db:"phone_number"             json:"phone_number,omitempty"`
	GoogleID               *string    `db:"google_id"                json:"google_id,omitempty"`
	Notified3D             *bool      `db:"notified_3d"              json:"notified_3d,omitempty"`
	Notified1D             *bool      `db:"notified_1d"              json:"notified_1d,omitempty"`
	CurrentPlan            *string    `db:"current_plan"             json:"current_plan,omitempty"`
	SubscriptionToken      *string    `db:"subscription_token"       json:"subscription_token,omitempty"`
	ActivationCode         *string    `db:"activation_code"          json:"activation_code,omitempty"`
	LastSeen               *time.Time `db:"last_seen"                json:"last_seen,omitempty"`
	LastIP                 string     `db:"last_ip"                  json:"last_ip"`
	LastUserAgent          string     `db:"last_user_agent"          json:"last_user_agent"`
	AppVersion             string     `db:"app_version"              json:"app_version"`
	OSName                 string     `db:"os_name"                  json:"os_name"`
	OSVersion              string     `db:"os_version"               json:"os_version"`
	LastCountry            string     `db:"last_country"             json:"last_country"`
	LastCountryName        string     `db:"last_country_name"        json:"last_country_name"`
	LastCity               string     `db:"last_city"                json:"last_city"`
	InitialIP              string     `db:"initial_ip"               json:"initial_ip"`
	InitialCountry         string     `db:"initial_country"          json:"initial_country"`
	InitialCountryName     string     `db:"initial_country_name"     json:"initial_country_name"`
	InitialCity            string     `db:"initial_city"             json:"initial_city"`
	Timezone               string     `db:"timezone"                 json:"timezone"`
	DeviceModel            string     `db:"device_model"             json:"device_model"`
	IOSVersion             string     `db:"ios_version"              json:"ios_version"`
	AcceptLanguage         string     `db:"accept_language"          json:"accept_language"`
	InstallDate            *time.Time `db:"install_date"             json:"install_date,omitempty"`
	StoreCountry           string     `db:"store_country"            json:"store_country"`
	Email                  *string    `db:"email"                    json:"email,omitempty"`
	EmailVerifiedAt        *time.Time `db:"email_verified_at"        json:"email_verified_at,omitempty"`
	PasswordHash           *string    `db:"password_hash"            json:"-"`
	CreatedAt              time.Time  `db:"created_at"               json:"created_at"`
	UpdatedAt              time.Time  `db:"updated_at"               json:"updated_at"`
}

// VPNServer represents a VPN server node (maps to "vpn_servers" table).
type VPNServer struct {
	ID               int64     `db:"id"                 json:"id"`
	Key              string    `db:"key"                json:"key"`
	Name             string    `db:"name"               json:"name"`
	Flag             string    `db:"flag"               json:"flag"`
	Host             string    `db:"host"               json:"host"`
	Port             int       `db:"port"               json:"port"`
	Domain           string    `db:"domain"             json:"domain"`
	SNI              string    `db:"sni"                json:"sni"`
	RealityPublicKey  string    `db:"reality_public_key"  json:"reality_public_key"`
	RealityPrivateKey string    `db:"reality_private_key" json:"-"`
	IsActive         bool      `db:"is_active"          json:"is_active"`
	SortOrder        int       `db:"sort_order"         json:"sort_order"`
	ProviderName     string    `db:"provider_name"      json:"provider_name"`
	CostMonthly      float64   `db:"cost_monthly"       json:"cost_monthly"`
	ProviderURL      string    `db:"provider_url"       json:"provider_url"`
	ProviderLogin    string    `db:"provider_login"     json:"-"`
	ProviderPassword string    `db:"provider_password"  json:"-"`
	Notes            string    `db:"notes"              json:"notes"`
	CreatedAt        time.Time `db:"created_at"         json:"created_at"`
	UpdatedAt        time.Time `db:"updated_at"         json:"updated_at"`
}

// AdminUser represents an admin panel user (maps to "admin_users" table).
type AdminUser struct {
	ID           int64      `db:"id"            json:"id"`
	Username     string     `db:"username"      json:"username"`
	PasswordHash string     `db:"password_hash" json:"-"`
	Role         string     `db:"role"          json:"role"`
	IsActive     bool       `db:"is_active"     json:"is_active"`
	LastLogin    *time.Time `db:"last_login"    json:"last_login,omitempty"`
	CreatedAt    time.Time  `db:"created_at"    json:"created_at"`
}

// TrafficSnapshot represents a traffic measurement (maps to "traffic_snapshots" table).
type TrafficSnapshot struct {
	ID              int64     `db:"id"               json:"id"`
	VPNUsername      string    `db:"vpn_username"     json:"vpn_username"`
	UsedTraffic     int64     `db:"used_traffic"     json:"used_traffic"`
	DownloadTraffic int64     `db:"download_traffic" json:"download_traffic"`
	UploadTraffic   int64     `db:"upload_traffic"   json:"upload_traffic"`
	Timestamp       time.Time `db:"timestamp"        json:"timestamp"`
}

// NodeMetricsHistory represents a node metrics sample (maps to "node_metrics_history" table).
type NodeMetricsHistory struct {
	ID          int64     `db:"id"           json:"id"`
	NodeKey     string    `db:"node_key"     json:"node_key"`
	CPU         *float32  `db:"cpu"          json:"cpu,omitempty"`
	RAMUsed     *float32  `db:"ram_used"     json:"ram_used,omitempty"`
	RAMTotal    *float32  `db:"ram_total"    json:"ram_total,omitempty"`
	Disk        *float32  `db:"disk"         json:"disk,omitempty"`
	TrafficUp   int64     `db:"traffic_up"   json:"traffic_up"`
	TrafficDown int64     `db:"traffic_down" json:"traffic_down"`
	OnlineUsers *int      `db:"online_users" json:"online_users,omitempty"`
	RecordedAt  time.Time `db:"recorded_at"  json:"recorded_at"`
}

// AppSetting represents a key-value application setting (maps to "app_settings" table).
type AppSetting struct {
	Key       string    `db:"key"        json:"key"`
	Value     string    `db:"value"      json:"value"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}
