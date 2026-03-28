"""Tests for Settings validation and parsing."""

from app.config import Settings


class TestSettings:
    def test_default_ports(self, settings):
        assert settings.vless_tcp_port == 2096
        assert settings.vless_grpc_port == 2098
        assert settings.vless_ws_port == 2099
        assert settings.xray_stats_port == 10085
        assert settings.hysteria2_port == 8443

    def test_snis_parsed(self, settings):
        assert isinstance(settings.reality_snis, list)
        assert len(settings.reality_snis) >= 1
        assert all(isinstance(s, str) for s in settings.reality_snis)

    def test_snis_from_comma_string(self):
        s = Settings(
            database_url="postgresql+asyncpg://x:x@localhost/x",
            reality_snis="foo.com, bar.com, baz.com",
            admin_username="admin",
            admin_password="pass",
        )
        assert s.reality_snis == ["foo.com", "bar.com", "baz.com"]

    def test_warp_reserved_from_string(self):
        s = Settings(
            database_url="postgresql+asyncpg://x:x@localhost/x",
            warp_reserved="1,2,3",
            admin_username="admin",
            admin_password="pass",
        )
        assert s.warp_reserved == [1, 2, 3]

    def test_warp_reserved_from_list(self):
        s = Settings(
            database_url="postgresql+asyncpg://x:x@localhost/x",
            warp_reserved=[10, 20, 30],
            admin_username="admin",
            admin_password="pass",
        )
        assert s.warp_reserved == [10, 20, 30]

    def test_node_ssh_passwords_empty(self, settings):
        assert isinstance(settings.node_ssh_passwords, dict)

    def test_awg_servers_empty(self, settings):
        assert settings.awg_servers == []

    def test_awg_servers_parsed(self):
        s = Settings(
            database_url="postgresql+asyncpg://x:x@localhost/x",
            awg_servers_raw="NL,1.2.3.4,8080,NL;DE,5.6.7.8,9090,DE",
            admin_username="admin",
            admin_password="pass",
        )
        servers = s.awg_servers
        assert len(servers) == 2
        assert servers[0]["name"] == "NL"
        assert servers[1]["host"] == "5.6.7.8"

    def test_cors_origins_from_string(self):
        s = Settings(
            database_url="postgresql+asyncpg://x:x@localhost/x",
            cors_origins="https://a.com, https://b.com",
            admin_username="admin",
            admin_password="pass",
        )
        assert s.cors_origins == ["https://a.com", "https://b.com"]
