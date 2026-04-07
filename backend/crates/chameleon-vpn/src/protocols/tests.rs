#[cfg(test)]
mod tests {
    use crate::protocols::*;
    use crate::protocols::registry::ProtocolRegistry;
    use chameleon_config::Settings;

    fn test_settings() -> Settings {
        unsafe {
            std::env::set_var("DATABASE_URL", "postgres://test:test@localhost/test");
            std::env::set_var("REDIS_URL", "redis://localhost:6379/0");
            std::env::set_var("ADMIN_USERNAME", "admin");
            std::env::set_var("ADMIN_PASSWORD", "testpassword123");
            std::env::set_var("REALITY_PRIVATE_KEY", "test_private_key");
            std::env::set_var("REALITY_PUBLIC_KEY", "test_public_key");
            std::env::set_var("HY2_PASSWORD", "hy2pass");
            std::env::set_var("HY2_OBFS_PASSWORD", "obfspass");
            std::env::set_var("ANYTLS_PASSWORD", "anytlspass");
            std::env::set_var("NAIVE_PASSWORD", "naivepass");
            std::env::set_var("NAIVE_USERNAME", "naiveuser");
        }
        Settings::load()
    }

    fn test_user() -> UserCredentials {
        UserCredentials { username: "testuser".into(), uuid: "550e8400-e29b-41d4-a716-446655440000".into(), short_id: "ab12".into() }
    }

    fn test_servers() -> Vec<ServerConfig> {
        vec![ServerConfig { host: "1.2.3.4".into(), port: 2096, domain: "vpn.example.com".into(), flag: "DE".into(), name: "DE".into(), key: "de".into(), sni: String::new() }]
    }

    #[test]
    fn test_registry_8_protocols() {
        let registry = ProtocolRegistry::new(&test_settings());
        assert_eq!(registry.all().len(), 8);
    }

    #[test]
    fn test_vless_reality_links() {
        let registry = ProtocolRegistry::new(&test_settings());
        let links = registry.get("vless_reality").unwrap().client_links(&test_user(), &test_servers());
        assert!(!links.is_empty());
        assert!(links[0].uri.starts_with("vless://"));
        assert!(links[0].uri.contains("reality"));
    }

    #[test]
    fn test_vless_reality_singbox() {
        let registry = ProtocolRegistry::new(&test_settings());
        let ob = registry.get("vless_reality").unwrap().singbox_outbound("t", &test_servers()[0], &test_user(), &OutboundOpts::default());
        assert!(ob.is_some());
        assert_eq!(ob.unwrap()["type"], "vless");
    }

    #[test]
    fn test_vless_reality_3_inbounds() {
        let registry = ProtocolRegistry::new(&test_settings());
        let inbounds = registry.get("vless_reality").unwrap().xray_inbounds(&[test_user()], &["ab12".into()]);
        assert_eq!(inbounds.len(), 3);
    }

    #[test]
    fn test_hysteria2_links() {
        let registry = ProtocolRegistry::new(&test_settings());
        let links = registry.get("hysteria2").unwrap().client_links(&test_user(), &test_servers());
        assert_eq!(links.len(), 1);
        assert!(links[0].uri.starts_with("hy2://"));
    }

    #[test]
    fn test_warp_no_links() {
        let registry = ProtocolRegistry::new(&test_settings());
        assert!(registry.get("warp").unwrap().client_links(&test_user(), &test_servers()).is_empty());
    }

    #[test]
    fn test_xdns_disabled() {
        let registry = ProtocolRegistry::new(&test_settings());
        assert!(!registry.get("xdns").unwrap().enabled());
    }

    #[test]
    fn test_anytls_outbound() {
        let registry = ProtocolRegistry::new(&test_settings());
        let ob = registry.get("anytls").unwrap().singbox_outbound("t", &test_servers()[0], &test_user(), &OutboundOpts::default()).unwrap();
        assert_eq!(ob["type"], "anytls");
    }
}
