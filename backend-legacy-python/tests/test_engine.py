"""Tests for ChameleonEngine — config generation logic (no DB/Redis needed)."""

from app.vpn.engine import (
    ChameleonEngine,
    _ensure_default_outbounds,
    _to_credentials,
    _xray_inbound_to_dict,
)
from app.vpn.protocols.base import XrayInbound


class TestHelpers:
    def test_to_credentials(self):
        users = [
            {"username": "alice", "uuid": "uuid-1", "short_id": "ab12"},
            {"username": "bob", "uuid": "uuid-2", "short_id": "cd34"},
        ]
        creds, short_ids = _to_credentials(users)
        assert len(creds) == 2
        assert creds[0].username == "alice"
        assert creds[1].uuid == "uuid-2"
        assert "ab12" in short_ids
        assert "cd34" in short_ids
        assert "" in short_ids  # Always includes empty

    def test_to_credentials_empty(self):
        creds, short_ids = _to_credentials([])
        assert creds == []
        assert "" in short_ids

    def test_ensure_default_outbounds_adds_missing(self):
        outbounds: list[dict] = []
        _ensure_default_outbounds(outbounds)
        tags = {o["tag"] for o in outbounds}
        assert "DIRECT" in tags
        assert "BLOCK" in tags

    def test_ensure_default_outbounds_no_duplicates(self):
        outbounds = [{"protocol": "freedom", "tag": "DIRECT"}]
        _ensure_default_outbounds(outbounds)
        direct_count = sum(1 for o in outbounds if o["tag"] == "DIRECT")
        assert direct_count == 1

    def test_xray_inbound_to_dict(self):
        ib = XrayInbound(
            tag="test-inbound",
            port=2096,
            protocol="vless",
            settings={"clients": []},
            stream_settings={"network": "tcp"},
            sniffing={"enabled": True},
        )
        d = _xray_inbound_to_dict(ib)
        assert d["tag"] == "test-inbound"
        assert d["port"] == 2096
        assert d["protocol"] == "vless"
        assert "settings" in d
        assert "streamSettings" in d
        assert "sniffing" in d
        # default listen (0.0.0.0) should NOT appear
        assert "listen" not in d

    def test_xray_inbound_custom_listen(self):
        ib = XrayInbound(tag="api", port=10085, protocol="dokodemo-door", listen="127.0.0.1")
        d = _xray_inbound_to_dict(ib)
        assert d["listen"] == "127.0.0.1"


class TestEngineConfigGeneration:
    def test_build_master_config_structure(self):
        engine = ChameleonEngine()
        users = [
            {"username": "alice", "uuid": "550e8400-e29b-41d4-a716-446655440000", "short_id": "ab12"},
        ]
        config = engine._build_master_config(users)
        assert "log" in config
        assert "inbounds" in config
        assert "outbounds" in config
        assert "routing" in config
        assert "dns" in config
        assert "stats" in config
        assert "api" in config

    def test_build_master_config_has_api_inbound(self):
        engine = ChameleonEngine()
        config = engine._build_master_config([])
        api_inbounds = [ib for ib in config["inbounds"] if ib["tag"] == "api"]
        assert len(api_inbounds) == 1
        assert api_inbounds[0]["port"] == 10085

    def test_build_node_config_structure(self):
        engine = ChameleonEngine()
        users = [
            {"username": "bob", "uuid": "660e8400-e29b-41d4-a716-446655440000", "short_id": "ef56"},
        ]
        config = engine._build_node_config(users)
        assert "inbounds" in config
        assert "outbounds" in config
        assert "routing" in config
        # Node config should NOT have stats/api
        assert "stats" not in config
        assert "api" not in config

    def test_build_master_config_empty_users(self):
        engine = ChameleonEngine()
        config = engine._build_master_config([])
        assert "inbounds" in config
        # Should still have at least the API inbound
        assert len(config["inbounds"]) >= 1
