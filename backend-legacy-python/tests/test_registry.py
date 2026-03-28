"""Tests for the protocol registry."""

import pytest

from app.vpn.protocols import registry


class TestRegistry:
    def test_has_protocols(self):
        protos = registry.all()
        assert len(protos) >= 6  # At least: vless_reality, vless_cdn, hy2, warp, anytls, naiveproxy

    def test_all_returns_list(self):
        protos = registry.all()
        assert isinstance(protos, list)

    def test_enabled_filters_correctly(self):
        enabled = registry.enabled()
        for p in enabled:
            assert p.enabled is True

    def test_enabled_is_subset_of_all(self):
        all_names = {p.name for p in registry.all()}
        enabled_names = {p.name for p in registry.enabled()}
        assert enabled_names.issubset(all_names)

    def test_get_known_protocol(self):
        proto = registry.get("vless_reality")
        assert proto.name == "vless_reality"

    def test_get_unknown_raises(self):
        with pytest.raises(KeyError):
            registry.get("nonexistent_protocol")

    def test_with_inbounds_excludes_outbound_only(self):
        inbound_protos = registry.with_inbounds()
        inbound_names = {p.name for p in inbound_protos}
        # WARP is outbound-only, should not be here
        assert "warp" not in inbound_names

    def test_with_links_returns_enabled(self):
        link_protos = registry.with_links()
        for p in link_protos:
            assert p.enabled is True
