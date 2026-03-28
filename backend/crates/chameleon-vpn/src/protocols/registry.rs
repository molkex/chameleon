//! Protocol registry — explicit initialization of all 8 protocols.

use chameleon_config::Settings;
use super::types::Protocol;
use super::{vless_reality, vless_cdn, hysteria2, warp, anytls, naiveproxy, xdns, xicmp};

pub struct ProtocolRegistry {
    protocols: Vec<Box<dyn Protocol>>,
}

impl ProtocolRegistry {
    /// Create registry with all protocols initialized from settings.
    pub fn new(config: &Settings) -> Self {
        let protocols: Vec<Box<dyn Protocol>> = vec![
            Box::new(vless_reality::VlessReality::new(config)),
            Box::new(vless_cdn::VlessCdn::new(config)),
            Box::new(hysteria2::Hysteria2::new(config)),
            Box::new(warp::Warp::new(config)),
            Box::new(anytls::AnyTls::new(config)),
            Box::new(naiveproxy::NaiveProxy::new(config)),
            Box::new(xdns::Xdns::new(config)),
            Box::new(xicmp::Xicmp::new(config)),
        ];
        Self { protocols }
    }

    pub fn all(&self) -> &[Box<dyn Protocol>] {
        &self.protocols
    }

    pub fn enabled(&self) -> Vec<&dyn Protocol> {
        self.protocols.iter().filter(|p| p.enabled()).map(|p| p.as_ref()).collect()
    }

    pub fn get(&self, name: &str) -> Option<&dyn Protocol> {
        self.protocols.iter().find(|p| p.name() == name).map(|p| p.as_ref())
    }

    /// Protocols that generate xray inbounds (not outbound-only like WARP).
    pub fn with_inbounds(&self) -> Vec<&dyn Protocol> {
        self.enabled()
            .into_iter()
            .filter(|p| !p.xray_inbounds(&[], &["".to_string()]).is_empty())
            .collect()
    }
}
