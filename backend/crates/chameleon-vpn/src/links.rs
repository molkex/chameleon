//! Subscription link generation — iterates protocol registry to build client links.

use base64::Engine;
use chrono::{DateTime, Utc, TimeZone};
use tracing::warn;

use super::protocols::{ClientLink, ServerConfig, UserCredentials, ProtocolRegistry};

/// Generate all client links by iterating enabled protocols.
pub fn generate_all_links(
    registry: &ProtocolRegistry,
    user: &UserCredentials,
    servers: &[ServerConfig],
) -> Vec<ClientLink> {
    let mut links = Vec::new();
    for protocol in registry.enabled() {
        links.extend(protocol.client_links(user, servers));
    }
    links
}

/// Format subscription response: header lines + VPN link URIs.
pub fn format_subscription_text(
    links: &[ClientLink],
    expire_ts: Option<i64>,
    branding: Option<&BrandingInfo>,
) -> String {
    let b = branding.cloned().unwrap_or_else(|| BrandingInfo::default());
    let header = if let Some(ts) = expire_ts {
        let dt = Utc.timestamp_opt(ts, 0).single().map(|d| d.format("%d.%m.%Y").to_string()).unwrap_or_default();
        format!("{} | До: {dt}", b.brand_name)
    } else {
        format!("{} | Без ограничений", b.brand_name)
    };

    let mut lines = vec![
        header,
        format!("Поддержка: {}", b.support_contact),
        format!("Канал: {}", b.channel_handle),
        String::new(),
    ];
    lines.extend(links.iter().map(|l| l.uri.clone()));
    lines.join("\n")
}

/// Generate subscription response HTTP headers.
pub fn get_subscription_headers(
    expire_ts: Option<i64>,
    upload: i64,
    download: i64,
    branding: Option<&BrandingInfo>,
) -> Vec<(String, String)> {
    let b = branding.cloned().unwrap_or_else(|| BrandingInfo::default());
    let b64 = base64::engine::general_purpose::STANDARD;
    vec![
        ("Cache-Control".into(), "no-cache".into()),
        ("profile-title".into(), b64.encode(b.profile_title.as_bytes())),
        ("profile-update-interval".into(), b.update_interval.clone()),
        ("support-url".into(), b.support_url.clone()),
        ("profile-web-page-url".into(), b.web_page_url.clone()),
        ("Subscription-Userinfo".into(), format!("upload={upload}; download={download}; total=0; expire={}", expire_ts.unwrap_or(0))),
    ]
}

#[derive(Debug, Clone)]
pub struct BrandingInfo {
    pub brand_name: String,
    pub profile_title: String,
    pub support_contact: String,
    pub channel_handle: String,
    pub support_url: String,
    pub web_page_url: String,
    pub update_interval: String,
}

impl Default for BrandingInfo {
    fn default() -> Self {
        Self {
            brand_name: "Chameleon VPN".into(),
            profile_title: "Chameleon VPN".into(),
            support_contact: String::new(),
            channel_handle: String::new(),
            support_url: String::new(),
            web_page_url: String::new(),
            update_interval: "12".into(),
        }
    }
}
