//! Application configuration loaded from environment variables and .env file.
//!
//! All fields map 1:1 to the Python `app/config.py` Settings class.

use rand::Rng;
use std::sync::OnceLock;

static SETTINGS: OnceLock<Settings> = OnceLock::new();

/// Generate a random 32-byte hex string for secrets that aren't configured.
fn random_hex_32() -> String {
    let bytes: [u8; 32] = rand::thread_rng().r#gen();
    hex::encode(&bytes)
}

/// Parse a comma-separated string into a Vec<String>.
fn parse_csv(s: &str) -> Vec<String> {
    s.split(',')
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .collect()
}

/// Parse a comma-separated string of ints.
fn parse_csv_ints(s: &str) -> Vec<i32> {
    s.split(',')
        .filter_map(|v| v.trim().parse().ok())
        .collect()
}

/// Simple hex encoder (avoids extra dependency).
mod hex {
    pub fn encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }
}

#[derive(Clone)]
pub struct Settings {
    // === Database ===
    pub database_url: String,
    pub redis_url: String,

    // === Admin Panel ===
    pub admin_username: String,
    pub admin_password: String,
    pub admin_session_secret: String,

    // === JWT ===
    pub admin_jwt_secret: String,
    pub mobile_jwt_secret: String,
    pub jwt_access_expire_minutes: i64,
    pub jwt_refresh_expire_days: i64,

    // === Apple Auth ===
    pub apple_team_id: String,
    pub apple_bundle_id: String,

    // === StoreKit ===
    pub appstore_key_id: String,
    pub appstore_issuer_id: String,
    pub appstore_private_key_path: String,
    pub appstore_environment: String,

    // === VPN: Reality ===
    pub reality_private_key: String,
    pub reality_public_key: String,
    pub reality_snis: Vec<String>,

    // === VPN: Ports ===
    pub vless_tcp_port: u16,
    pub vless_grpc_port: u16,
    pub vless_ws_port: u16,
    pub xray_stats_port: u16,
    pub hysteria2_port: u16,

    // === VPN: Hysteria2 ===
    pub hy2_password: String,
    pub hy2_obfs_password: String,
    pub hy2_sni: String,
    pub hy2_cert_sha256: String,
    pub hy2_tls_insecure: bool,

    // === WARP ===
    pub warp_private_key: String,
    pub warp_address_v4: String,
    pub warp_address_v6: String,
    pub warp_endpoint: String,
    pub warp_reserved: Vec<i32>,
    pub warp_domains: Vec<String>,

    // === AnyTLS ===
    pub anytls_port: u16,
    pub anytls_password: String,
    pub anytls_sni: String,

    // === NaiveProxy ===
    pub naive_port: u16,
    pub naive_username: String,
    pub naive_password: String,
    pub naive_domain: String,

    // === AmneziaWG ===
    pub awg_password: String,
    pub awg_servers: Vec<AwgServer>,

    // === CDN ===
    pub cdn_domain: String,

    // === Servers ===
    pub vpn_servers_raw: String,
    pub relay_servers_raw: String,

    // === Node SSH ===
    pub deploy_password_nl: String,
    pub deploy_password_de_ovh: String,

    // === Cloudflare ===
    pub cloudflare_email: String,
    pub cloudflare_api_key: String,
    pub cloudflare_zone_id: String,

    // === DNS ===
    pub adguard_dns: String,

    // === Device Limits ===
    pub max_devices_per_user: i32,

    // === Monitoring ===
    pub monitor_api_key: String,

    // === CORS ===
    pub cors_origins: Vec<String>,

    // === HA ===
    pub standby_mode: bool,

    // === FinalMask / Padding ===
    pub finalmask_mode: String,
    pub padding_mode: String,

    // === Emergency Protocols ===
    pub xdns_domain: String,
    pub xdns_enabled: bool,
    pub xicmp_enabled: bool,

    // === Xray ===
    pub xray_version: String,

    // === Webhooks ===
    pub webhook_urls: Vec<String>,
    pub webhook_secret: String,

    // === Node Pull API ===
    pub node_api_key: String,

    // === Subscription ===
    pub trial_days: i32,

    // === Security ===
    pub admin_ip_allowlist: Vec<String>,

    // === Uploads ===
    pub upload_dir: String,

    // === Cluster ===
    pub cluster_secret: String,
    pub cluster_peers: Vec<String>,
    pub node_id: String,

    // === Environment ===
    pub environment: String,
}

#[derive(Debug, Clone)]
pub struct AwgServer {
    pub name: String,
    pub host: String,
    pub api_port: u16,
    pub flag: String,
}

fn hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("HOST"))
        .unwrap_or_else(|_| "unknown".to_string())
}

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_default()
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_bool(key: &str) -> bool {
    matches!(env(key).to_lowercase().as_str(), "true" | "1" | "yes")
}

fn env_i32(key: &str, default: i32) -> i32 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_i64(key: &str, default: i64) -> i64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_u16(key: &str, default: u16) -> u16 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn parse_awg_servers(raw: &str) -> Vec<AwgServer> {
    raw.split(';')
        .filter_map(|entry| {
            let parts: Vec<&str> = entry.trim().split(',').collect();
            if parts.len() >= 4 {
                Some(AwgServer {
                    name: parts[0].trim().to_string(),
                    host: parts[1].trim().to_string(),
                    api_port: parts[2].trim().parse().ok()?,
                    flag: parts[3].trim().to_string(),
                })
            } else {
                None
            }
        })
        .collect()
}

impl Settings {
    /// Load settings from environment variables. Call after `dotenvy::dotenv()`.
    pub fn load() -> Self {
        dotenvy::dotenv().ok();

        let awg_raw = env("AWG_SERVERS_RAW");

        Self {
            database_url: env("DATABASE_URL"),
            redis_url: env_or("REDIS_URL", "redis://127.0.0.1:6379/0"),

            admin_username: env("ADMIN_USERNAME"),
            admin_password: env("ADMIN_PASSWORD"),
            admin_session_secret: std::env::var("ADMIN_SESSION_SECRET")
                .unwrap_or_else(|_| random_hex_32()),

            admin_jwt_secret: std::env::var("ADMIN_JWT_SECRET")
                .unwrap_or_else(|_| random_hex_32()),
            mobile_jwt_secret: std::env::var("MOBILE_JWT_SECRET")
                .unwrap_or_else(|_| random_hex_32()),
            jwt_access_expire_minutes: env_i64("JWT_ACCESS_EXPIRE_MINUTES", 15),
            jwt_refresh_expire_days: env_i64("JWT_REFRESH_EXPIRE_DAYS", 90),

            apple_team_id: env("APPLE_TEAM_ID"),
            apple_bundle_id: env_or("APPLE_BUNDLE_ID", "com.example.vpn"),

            appstore_key_id: env("APPSTORE_KEY_ID"),
            appstore_issuer_id: env("APPSTORE_ISSUER_ID"),
            appstore_private_key_path: env("APPSTORE_PRIVATE_KEY_PATH"),
            appstore_environment: env_or("APPSTORE_ENVIRONMENT", "Sandbox"),

            reality_private_key: env("REALITY_PRIVATE_KEY"),
            reality_public_key: env("REALITY_PUBLIC_KEY"),
            reality_snis: parse_csv(&env_or("REALITY_SNIS", "ads.x5.ru")),

            vless_tcp_port: env_u16("VLESS_TCP_PORT", 2096),
            vless_grpc_port: env_u16("VLESS_GRPC_PORT", 2098),
            vless_ws_port: env_u16("VLESS_WS_PORT", 2099),
            xray_stats_port: env_u16("XRAY_STATS_PORT", 10085),
            hysteria2_port: env_u16("HYSTERIA2_PORT", 8443),

            hy2_password: env("HY2_PASSWORD"),
            hy2_obfs_password: env("HY2_OBFS_PASSWORD"),
            hy2_sni: env_or("HY2_SNI", "rutube.ru"),
            hy2_cert_sha256: env("HY2_CERT_SHA256"),
            hy2_tls_insecure: env_bool("HY2_TLS_INSECURE"),

            warp_private_key: env("WARP_PRIVATE_KEY"),
            warp_address_v4: env_or("WARP_ADDRESS_V4", "172.16.0.2/32"),
            warp_address_v6: env("WARP_ADDRESS_V6"),
            warp_endpoint: env_or("WARP_ENDPOINT", "engage.cloudflareclient.com:2408"),
            warp_reserved: parse_csv_ints(&env_or("WARP_RESERVED", "0,0,0")),
            warp_domains: parse_csv(&env("WARP_DOMAINS")),

            anytls_port: env_u16("ANYTLS_PORT", 2100),
            anytls_password: env("ANYTLS_PASSWORD"),
            anytls_sni: env_or("ANYTLS_SNI", "www.microsoft.com"),

            naive_port: env_u16("NAIVE_PORT", 8443),
            naive_username: env("NAIVE_USERNAME"),
            naive_password: env("NAIVE_PASSWORD"),
            naive_domain: env("NAIVE_DOMAIN"),

            awg_password: env("AWG_PASSWORD"),
            awg_servers: parse_awg_servers(&awg_raw),

            cdn_domain: env("CDN_DOMAIN"),

            vpn_servers_raw: env("VPN_SERVERS"),
            relay_servers_raw: env("RELAY_SERVERS"),

            deploy_password_nl: env("DEPLOY_PASSWORD_NL"),
            deploy_password_de_ovh: env("DEPLOY_PASSWORD_DE_OVH"),

            cloudflare_email: env("CLOUDFLARE_EMAIL"),
            cloudflare_api_key: env("CLOUDFLARE_API_KEY"),
            cloudflare_zone_id: env("CLOUDFLARE_ZONE_ID"),

            adguard_dns: env("ADGUARD_DNS"),

            max_devices_per_user: env_i32("MAX_DEVICES_PER_USER", 0),

            monitor_api_key: env("MONITOR_API_KEY"),

            cors_origins: parse_csv(&env("CORS_ORIGINS")),

            standby_mode: env_bool("STANDBY_MODE"),

            finalmask_mode: env_or("FINALMASK_MODE", "salamander"),
            padding_mode: env_or("PADDING_MODE", "auto"),

            xdns_domain: env("XDNS_DOMAIN"),
            xdns_enabled: env_bool("XDNS_ENABLED"),
            xicmp_enabled: env_bool("XICMP_ENABLED"),

            xray_version: env_or("XRAY_VERSION", "26.3.27"),

            webhook_urls: parse_csv(&env("WEBHOOK_URLS")),
            webhook_secret: env("WEBHOOK_SECRET"),

            node_api_key: env("NODE_API_KEY"),

            trial_days: env_i32("TRIAL_DAYS", 7),

            admin_ip_allowlist: parse_csv(&env("ADMIN_IP_ALLOWLIST")),

            upload_dir: env_or("UPLOAD_DIR", "/app/uploads"),

            cluster_secret: std::env::var("CLUSTER_SECRET")
                .unwrap_or_else(|_| random_hex_32()),
            cluster_peers: parse_csv(&env("CLUSTER_PEERS")),
            node_id: std::env::var("NODE_ID")
                .unwrap_or_else(|_| hostname()),

            environment: env_or("ENVIRONMENT", "production"),
        }
    }

    /// Validate critical settings. Returns (fatal_errors, warnings).
    pub fn validate(&self) -> (Vec<String>, Vec<String>) {
        let mut errors = vec![];
        let mut warnings = vec![];

        if self.database_url.is_empty() {
            errors.push("DATABASE_URL is required".into());
        }
        if self.redis_url.is_empty() {
            errors.push("REDIS_URL is required".into());
        }
        if self.admin_username.is_empty() || self.admin_password.is_empty() {
            errors.push("ADMIN_USERNAME and ADMIN_PASSWORD are required".into());
        }
        if !self.admin_password.is_empty() && self.admin_password.len() < 8 {
            errors.push("ADMIN_PASSWORD must be at least 8 characters".into());
        }
        if self.reality_private_key.is_empty() {
            errors.push("REALITY_PRIVATE_KEY is required for VLESS Reality".into());
        }

        // Non-fatal warnings
        if std::env::var("ADMIN_JWT_SECRET").is_err() {
            warnings.push("ADMIN_JWT_SECRET not set — sessions invalidated on restart".into());
        }
        if std::env::var("MOBILE_JWT_SECRET").is_err() {
            warnings.push("MOBILE_JWT_SECRET not set — mobile tokens invalidated on restart".into());
        }
        if self.node_api_key.is_empty() {
            warnings.push("NODE_API_KEY not set — node API is unprotected".into());
        }
        (errors, warnings)
    }

    pub fn is_dev(&self) -> bool {
        self.environment != "production"
    }
}

/// Get the global settings singleton.
pub fn get_settings() -> &'static Settings {
    SETTINGS.get_or_init(Settings::load)
}

impl std::fmt::Debug for Settings {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Settings")
            .field("environment", &self.environment)
            .field("database_url", &"[REDACTED]")
            .field("redis_url", &"[REDACTED]")
            .field("admin_username", &self.admin_username)
            .field("vless_tcp_port", &self.vless_tcp_port)
            .field("hysteria2_port", &self.hysteria2_port)
            .field("cors_origins", &self.cors_origins)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_csv() {
        assert_eq!(parse_csv("a,b,c"), vec!["a", "b", "c"]);
        assert_eq!(parse_csv(" a , b "), vec!["a", "b"]);
        assert_eq!(parse_csv(""), Vec::<String>::new());
    }

    #[test]
    fn test_parse_csv_ints() {
        assert_eq!(parse_csv_ints("1,2,3"), vec![1, 2, 3]);
        assert_eq!(parse_csv_ints("0,0,0"), vec![0, 0, 0]);
    }

    #[test]
    fn test_parse_awg_servers() {
        let servers = parse_awg_servers("NL,1.2.3.4,51820,🇳🇱;DE,5.6.7.8,51821,🇩🇪");
        assert_eq!(servers.len(), 2);
        assert_eq!(servers[0].name, "NL");
        assert_eq!(servers[1].api_port, 51821);
    }
}
