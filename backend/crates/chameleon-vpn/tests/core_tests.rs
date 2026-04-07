//! Integration-style tests for VPN core functionality.
//! These do NOT require a database — they test pure logic.

use chameleon_vpn::protocols::*;
use chameleon_vpn::protocols::registry::ProtocolRegistry;
use chameleon_vpn::singbox;
use chameleon_vpn::links;

fn setup_env() {
    unsafe {
        std::env::set_var("DATABASE_URL", "postgres://test:test@localhost/test");
        std::env::set_var("REDIS_URL", "redis://localhost:6379/0");
        std::env::set_var("ADMIN_USERNAME", "admin");
        std::env::set_var("ADMIN_PASSWORD", "testpassword123");
        std::env::set_var("REALITY_PRIVATE_KEY", "test_priv_key_32bytes_hex_1234567");
        std::env::set_var("REALITY_PUBLIC_KEY", "test_pub_key");
        std::env::set_var("HY2_PASSWORD", "hy2pass");
        std::env::set_var("HY2_OBFS_PASSWORD", "obfspass");
        std::env::set_var("ANYTLS_PASSWORD", "anytlspass");
        std::env::set_var("NAIVE_PASSWORD", "naivepass");
        std::env::set_var("NAIVE_USERNAME", "naiveuser");
    }
}

fn test_user() -> UserCredentials {
    UserCredentials {
        username: "testuser".to_string(),
        uuid: "550e8400-e29b-41d4-a716-446655440000".to_string(),
        short_id: "ab12".to_string(),
    }
}

fn test_servers() -> Vec<ServerConfig> {
    vec![
        ServerConfig {
            host: "1.2.3.4".into(), port: 2096, domain: "vpn.example.com".into(),
            flag: "DE".into(), name: "DE".into(), key: "de".into(), sni: String::new(),
        },
        ServerConfig {
            host: "5.6.7.8".into(), port: 2096, domain: "vpn2.example.com".into(),
            flag: "NL".into(), name: "NL".into(), key: "nl".into(), sni: String::new(),
        },
    ]
}

#[test]
fn test_singbox_config_structure() {
    setup_env();
    let settings = chameleon_config::Settings::load();
    let registry = ProtocolRegistry::new(&settings);
    let config = singbox::generate_config(&registry, &test_user(), &test_servers());

    assert!(config.get("dns").is_some());
    assert!(config.get("inbounds").is_some());
    assert!(config.get("outbounds").is_some());
    assert!(config.get("route").is_some());
    assert_eq!(config["inbounds"][0]["type"], "tun");

    let outbounds = config["outbounds"].as_array().unwrap();
    assert!(outbounds.len() >= 5);
    assert!(outbounds.iter().any(|o| o["tag"] == "Auto"));
    assert!(outbounds.iter().any(|o| o["tag"] == "Proxy"));
    assert!(outbounds.iter().any(|o| o["tag"] == "Direct"));
    assert!(outbounds.iter().any(|o| o["tag"] == "Block"));
}

#[test]
fn test_singbox_has_protocol_outbounds() {
    setup_env();
    let settings = chameleon_config::Settings::load();
    let registry = ProtocolRegistry::new(&settings);
    let config = singbox::generate_config(&registry, &test_user(), &test_servers());
    let outbounds = config["outbounds"].as_array().unwrap();
    assert!(outbounds.iter().any(|o| o["type"] == "vless"));
    assert!(outbounds.iter().any(|o| o["type"] == "hysteria2"));
}

#[test]
fn test_links_generation() {
    setup_env();
    let settings = chameleon_config::Settings::load();
    let registry = ProtocolRegistry::new(&settings);
    let all_links = links::generate_all_links(&registry, &test_user(), &test_servers());

    assert!(!all_links.is_empty());
    assert!(all_links.iter().any(|l| l.protocol == "vless"));
    assert!(all_links.iter().any(|l| l.protocol == "hysteria2"));
    for link in &all_links {
        assert!(!link.uri.is_empty());
    }
}

#[test]
fn test_subscription_text_format() {
    setup_env();
    let settings = chameleon_config::Settings::load();
    let registry = ProtocolRegistry::new(&settings);
    let all_links = links::generate_all_links(&registry, &test_user(), &test_servers());
    let text = links::format_subscription_text(&all_links, Some(1735689600), None);
    assert!(text.contains("Chameleon VPN"));
    assert!(text.contains("vless://"));
}

#[test]
fn test_subscription_headers() {
    let headers = links::get_subscription_headers(Some(1735689600), 1000, 2000, None);
    assert!(headers.iter().any(|(k, _)| k == "Subscription-Userinfo"));
}

#[test]
fn test_engine_master_config() {
    setup_env();
    let settings = chameleon_config::Settings::load();
    let engine = chameleon_vpn::engine::ChameleonEngine::new(&settings).unwrap();
    let users = vec![chameleon_vpn::engine::ActiveUser {
        username: "user1".into(), uuid: "550e8400-e29b-41d4-a716-446655440000".into(), short_id: "ab12".into(),
    }];
    let config = engine.build_master_config(&users);

    assert!(config.get("stats").is_some());
    assert!(config.get("api").is_some());
    let inbounds = config["inbounds"].as_array().unwrap();
    assert!(inbounds.len() >= 4); // api + 3 VLESS
    let outbounds = config["outbounds"].as_array().unwrap();
    assert!(outbounds.iter().any(|o| o["tag"] == "DIRECT"));
    assert!(outbounds.iter().any(|o| o["tag"] == "BLOCK"));
}

#[test]
fn test_engine_node_config_no_api() {
    setup_env();
    let settings = chameleon_config::Settings::load();
    let engine = chameleon_vpn::engine::ChameleonEngine::new(&settings).unwrap();
    let users = vec![chameleon_vpn::engine::ActiveUser {
        username: "user1".into(), uuid: "550e8400-e29b-41d4-a716-446655440000".into(), short_id: "ab12".into(),
    }];
    let config = engine.build_node_config(&users);
    assert!(config.get("stats").is_none());
    assert!(config.get("api").is_none());
    assert!(config.get("inbounds").is_some());
}
