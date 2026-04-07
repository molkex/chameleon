//! Database row structs mapping 1:1 to PostgreSQL tables.
//! All fields match the existing Python SQLAlchemy models exactly.

use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};
use sqlx::FromRow;

// ── User ──

#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct User {
    pub id: i32,
    pub telegram_id: Option<i64>,
    pub username: Option<String>,
    pub full_name: Option<String>,
    pub is_active: bool,
    pub subscription_expiry: Option<NaiveDateTime>,
    pub vpn_username: Option<String>,
    pub vpn_uuid: Option<String>,
    pub vpn_short_id: Option<String>,
    pub auth_provider: Option<String>,
    pub apple_id: Option<String>,
    pub device_id: Option<String>,
    pub original_transaction_id: Option<String>,
    pub app_store_product_id: Option<String>,
    pub ad_source: Option<String>,
    pub cumulative_traffic: Option<i64>,
    pub device_limit: Option<i32>,
    pub bot_blocked_at: Option<NaiveDateTime>,
    pub phone_number: Option<String>,
    pub google_id: Option<String>,
    pub notified_3d: Option<bool>,
    pub notified_1d: Option<bool>,
    pub current_plan: Option<String>,
    pub subscription_token: Option<String>,
    pub activation_code: Option<String>,
    pub created_at: Option<NaiveDateTime>,
    pub updated_at: Option<NaiveDateTime>,
}

// ── Transaction ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct Transaction {
    pub id: i32,
    pub user_id: Option<i32>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub provider_payment_charge_id: Option<String>,
    pub status: Option<String>,
    pub description: Option<String>,
    pub plan: Option<String>,
    pub created_at: Option<NaiveDateTime>,
}

// ── ProxyStats ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct ProxyStats {
    pub id: i32,
    pub date: Option<chrono::NaiveDate>,
    pub unique_clicks: Option<i32>,
    pub total_clicks: Option<i32>,
}

// ── ProxyClick ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct ProxyClick {
    pub id: i32,
    pub user_id: Option<i32>,
    pub clicked_at: Option<NaiveDateTime>,
}

// ── TrafficSnapshot ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct TrafficSnapshot {
    pub id: i32,
    pub vpn_username: Option<String>,
    pub used_traffic: Option<i64>,
    pub download_traffic: Option<i64>,
    pub upload_traffic: Option<i64>,
    pub timestamp: Option<NaiveDateTime>,
}

// ── MonitorCheck ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct MonitorCheck {
    pub id: i32,
    pub resource: Option<String>,
    pub url: Option<String>,
    pub category: Option<String>,
    pub via_vpn: Option<bool>,
    pub is_available: Option<bool>,
    pub is_throttled: Option<bool>,
    pub is_geo_blocked: Option<bool>,
    pub response_time_ms: Option<f64>,
    pub download_speed_kbps: Option<f64>,
    pub dns_resolved: Option<bool>,
    pub exit_ip: Option<String>,
    pub http_status: Option<i32>,
    pub error_message: Option<String>,
    pub protocol: Option<String>,
    pub checked_at: Option<NaiveDateTime>,
}

// ── AnalyticsEvent ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct AnalyticsEvent {
    pub id: i32,
    pub user_id: Option<i32>,
    pub event_type: Option<String>,
    pub event_data: Option<serde_json::Value>,
    pub timestamp: Option<NaiveDateTime>,
}

// ── DomainStats ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct DomainStats {
    pub id: i32,
    pub date: Option<chrono::NaiveDate>,
    pub domain: Option<String>,
    pub category: Option<String>,
    pub hit_count: Option<i32>,
    pub unique_users: Option<i32>,
    pub users_list: Option<serde_json::Value>,
}

// ── AdCampaign ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct AdCampaign {
    pub id: i32,
    pub slug: String,
    pub name: Option<String>,
    pub channel: Option<String>,
    pub budget_rub: Option<f64>,
    pub notes: Option<String>,
    pub created_at: Option<NaiveDateTime>,
}

// ── VpnTestResult ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct VpnTestResult {
    pub id: i32,
    pub username: Option<String>,
    pub client_ip: Option<String>,
    pub isp: Option<String>,
    pub asn: Option<String>,
    pub country: Option<String>,
    pub city: Option<String>,
    pub vpn_detected: Option<bool>,
    pub overall_score: Option<f64>,
    pub connectivity_score: Option<f64>,
    pub speed_score: Option<f64>,
    pub security_score: Option<f64>,
    pub download_mbps: Option<f64>,
    pub upload_mbps: Option<f64>,
    pub ping_ms: Option<f64>,
    pub platform: Option<String>,
    pub browser: Option<String>,
    pub connection_type: Option<String>,
    pub configs_working: Option<i32>,
    pub configs_total: Option<i32>,
    pub best_config_name: Option<String>,
    pub best_config_download: Option<f64>,
    pub best_config_upload: Option<f64>,
    pub best_config_ping: Option<f64>,
    pub xhttp_available: Option<bool>,
    pub grpc_available: Option<bool>,
    pub hy2_available: Option<bool>,
    pub issues_json: Option<serde_json::Value>,
    pub results_json: Option<serde_json::Value>,
    pub tested_at: Option<NaiveDateTime>,
}

// ── AdminUser ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct AdminUser {
    pub id: i32,
    pub username: String,
    pub password_hash: String,
    pub role: String,
    pub is_active: bool,
    pub last_login: Option<NaiveDateTime>,
    pub created_at: Option<NaiveDateTime>,
}

// ── AdminAuditLog ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct AdminAuditLog {
    pub id: i32,
    pub admin_user_id: Option<i32>,
    pub action: String,
    pub ip: String,
    pub user_agent: Option<String>,
    pub details: Option<String>,
    pub created_at: Option<NaiveDateTime>,
}

// ── AppSetting ──

#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct AppSetting {
    pub key: String,
    pub value: String,
    pub updated_at: Option<NaiveDateTime>,
}

// ── VpnServer ──

#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct VpnServer {
    pub id: i32,
    pub key: String,
    pub name: String,
    pub flag: String,
    pub host: String,
    pub port: i32,
    pub domain: String,
    pub sni: String,
    pub is_active: bool,
    pub sort_order: i32,
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
    pub updated_at: Option<chrono::DateTime<chrono::Utc>>,
}

// ── SupportMessage ──

#[derive(Debug, Clone, FromRow, Serialize)]
pub struct SupportMessage {
    pub id: i32,
    pub user_id: i32,
    pub direction: String, // "user" or "admin"
    pub content: String,
    pub attachments: Option<serde_json::Value>,
    pub is_read: bool,
    pub created_at: Option<NaiveDateTime>,
}
