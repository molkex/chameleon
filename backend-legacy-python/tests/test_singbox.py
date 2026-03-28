"""Tests for sing-box config generation."""

import json

from app.vpn.singbox_config import (
    BLOCKED_DOMAIN_SUFFIXES,
    DIRECT_OUTBOUND,
    TUN_INBOUND,
    generate_singbox_config,
    generate_singbox_json,
)


class TestSingboxConfig:
    def test_generate_config_structure(self, test_user, test_servers):
        config = generate_singbox_config(test_user, test_servers)
        assert config is not None
        assert "outbounds" in config
        assert "route" in config
        assert "dns" in config
        assert "inbounds" in config
        assert "log" in config

    def test_has_tun_inbound(self, test_user, test_servers):
        config = generate_singbox_config(test_user, test_servers)
        assert config is not None
        inbound_types = [ib["type"] for ib in config["inbounds"]]
        assert "tun" in inbound_types

    def test_has_direct_outbound(self, test_user, test_servers):
        config = generate_singbox_config(test_user, test_servers)
        assert config is not None
        outbound_tags = [ob["tag"] for ob in config["outbounds"]]
        assert "direct" in outbound_tags

    def test_has_selector_and_auto(self, test_user, test_servers):
        config = generate_singbox_config(test_user, test_servers)
        assert config is not None
        outbound_tags = [ob["tag"] for ob in config["outbounds"]]
        assert "proxy" in outbound_tags
        assert "auto" in outbound_tags

    def test_smart_mode_final_direct(self, test_user, test_servers):
        config = generate_singbox_config(test_user, test_servers, mode="smart")
        assert config is not None
        assert config["route"]["final"] == "direct"

    def test_fullvpn_mode_final_proxy(self, test_user, test_servers):
        config = generate_singbox_config(test_user, test_servers, mode="fullvpn")
        assert config is not None
        assert config["route"]["final"] == "proxy"

    def test_generate_json_returns_string(self, test_user, test_servers):
        result = generate_singbox_json(test_user, test_servers)
        assert result is not None
        assert isinstance(result, str)
        parsed = json.loads(result)
        assert "outbounds" in parsed

    def test_dns_has_servers(self, test_user, test_servers):
        config = generate_singbox_config(test_user, test_servers)
        assert config is not None
        assert len(config["dns"]["servers"]) >= 2

    def test_route_has_rules(self, test_user, test_servers):
        config = generate_singbox_config(test_user, test_servers)
        assert config is not None
        assert len(config["route"]["rules"]) >= 2  # sniff + hijack-dns at minimum


class TestConstants:
    def test_tun_inbound_structure(self):
        assert TUN_INBOUND["type"] == "tun"
        assert "address" in TUN_INBOUND
        assert TUN_INBOUND["auto_route"] is True

    def test_direct_outbound_structure(self):
        assert DIRECT_OUTBOUND["type"] == "direct"
        assert DIRECT_OUTBOUND["tag"] == "direct"

    def test_blocked_domains_is_list(self):
        assert isinstance(BLOCKED_DOMAIN_SUFFIXES, list)
