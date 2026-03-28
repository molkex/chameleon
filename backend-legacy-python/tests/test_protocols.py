"""Tests for protocol plugins — verify each protocol implements the interface correctly."""

import pytest

from app.vpn.protocols.vless_reality import VlessReality
from app.vpn.protocols.hysteria2 import Hysteria2
from app.vpn.protocols.warp import Warp
from app.vpn.protocols.anytls import AnyTLS
from app.vpn.protocols.vless_cdn import VlessCdn
from app.vpn.protocols.naiveproxy import NaiveProxy
from app.vpn.protocols import registry


# ── VLESS Reality ──


class TestVlessReality:
    def test_generates_links(self, test_user, test_servers):
        proto = VlessReality()
        links = proto.client_links(test_user, test_servers)
        assert len(links) > 0
        assert all(lk.uri.startswith("vless://") for lk in links)

    def test_links_contain_uuid(self, test_user, test_servers):
        proto = VlessReality()
        links = proto.client_links(test_user, test_servers)
        for lk in links:
            assert test_user.uuid in lk.uri

    def test_generates_inbounds(self, test_user):
        proto = VlessReality()
        inbounds = proto.xray_inbounds([test_user], ["abcd1234"])
        assert len(inbounds) == 3  # TCP, XHTTP, gRPC
        tags = [ib.tag for ib in inbounds]
        assert "VLESS TCP REALITY" in tags
        assert "VLESS XHTTP REALITY" in tags
        assert "VLESS gRPC REALITY" in tags

    def test_singbox_outbound_tcp(self, test_user, test_servers):
        proto = VlessReality()
        ob = proto.singbox_outbound("test-tag", test_servers[0], test_user, transport="tcp")
        assert ob is not None
        assert ob["type"] == "vless"
        assert ob["tag"] == "test-tag"
        assert ob["uuid"] == test_user.uuid
        assert ob["flow"] == "xtls-rprx-vision"

    def test_singbox_outbound_grpc(self, test_user, test_servers):
        proto = VlessReality()
        ob = proto.singbox_outbound("test-grpc", test_servers[0], test_user, transport="grpc")
        assert ob is not None
        assert "transport" in ob
        assert ob["transport"]["type"] == "grpc"
        assert "flow" not in ob  # gRPC has no flow

    def test_name_and_display(self):
        proto = VlessReality()
        assert proto.name == "vless_reality"
        assert proto.display_name == "VLESS Reality"
        assert proto.enabled is True


# ── Hysteria2 ──


class TestHysteria2:
    def test_disabled_without_password(self):
        proto = Hysteria2()
        # In test env HY2_PASSWORD is empty
        assert proto.enabled is False

    def test_no_links_when_disabled(self, test_user, test_servers):
        proto = Hysteria2()
        links = proto.client_links(test_user, test_servers)
        assert links == []

    def test_no_xray_inbounds(self, test_user):
        proto = Hysteria2()
        inbounds = proto.xray_inbounds([test_user], ["abcd1234"])
        assert inbounds == []  # Separate binary

    def test_singbox_outbound_none_when_disabled(self, test_user, test_servers):
        proto = Hysteria2()
        ob = proto.singbox_outbound("hy2-tag", test_servers[0], test_user)
        assert ob is None

    def test_name(self):
        proto = Hysteria2()
        assert proto.name == "hysteria2"


# ── WARP ──


class TestWarp:
    def test_no_client_links(self, test_user, test_servers):
        proto = Warp()
        links = proto.client_links(test_user, test_servers)
        assert links == []  # WARP is outbound-only

    def test_no_xray_inbounds(self, test_user):
        proto = Warp()
        inbounds = proto.xray_inbounds([test_user], ["abcd1234"])
        assert inbounds == []

    def test_name(self):
        proto = Warp()
        assert proto.name == "warp"
        assert proto.display_name == "WARP+"


# ── AnyTLS ──


class TestAnyTLS:
    def test_disabled_without_password(self):
        proto = AnyTLS()
        assert proto.enabled is False

    def test_no_xray_inbounds(self, test_user):
        proto = AnyTLS()
        inbounds = proto.xray_inbounds([test_user], ["abcd1234"])
        assert inbounds == []

    def test_singbox_outbound_none_when_disabled(self, test_user, test_servers):
        proto = AnyTLS()
        ob = proto.singbox_outbound("anytls-tag", test_servers[0], test_user)
        assert ob is None

    def test_name(self):
        proto = AnyTLS()
        assert proto.name == "anytls"


# ── Interface compliance ──


class TestProtocolInterface:
    def test_all_protocols_implement_interface(self):
        """Every registered protocol must implement the full Protocol interface."""
        for proto in registry.all():
            assert hasattr(proto, "name")
            assert hasattr(proto, "display_name")
            assert hasattr(proto, "enabled")
            assert callable(proto.xray_inbounds)
            assert callable(proto.client_links)
            assert callable(proto.singbox_outbound)

    def test_all_protocols_have_unique_names(self):
        names = [p.name for p in registry.all()]
        assert len(names) == len(set(names)), f"Duplicate protocol names: {names}"

    def test_xray_outbounds_returns_list(self):
        for proto in registry.all():
            result = proto.xray_outbounds()
            assert isinstance(result, list)

    def test_xray_routing_rules_returns_list(self):
        for proto in registry.all():
            result = proto.xray_routing_rules()
            assert isinstance(result, list)
