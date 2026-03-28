"""NaiveProxy — real Chromium networking stack, unfingerprintable.

Server-side runs via caddy/nginx with forward_proxy plugin, NOT xray.
sing-box 1.13+ supports naive outbound with QUIC + ECH + BBR.
"""

from urllib.parse import quote

from app.config import get_settings

from .base import ClientLink, Protocol, ServerConfig, UserCredentials, XrayInbound


class NaiveProxy(Protocol):
    def __init__(self) -> None:
        s = get_settings()
        self._port = s.naive_port
        self._username = s.naive_username
        self._password = s.naive_password
        self._domain = s.naive_domain

    @property
    def name(self) -> str:
        return "naiveproxy"

    @property
    def display_name(self) -> str:
        return "NaiveProxy"

    @property
    def enabled(self) -> bool:
        return bool(self._password)

    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        return []  # NaiveProxy runs via caddy/nginx, not xray

    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]:
        links: list[ClientLink] = []
        for srv in servers:
            domain = self._domain or srv.domain or srv.host
            remark = f"{srv.flag} {srv.name} Naive"
            uri = (
                f"naive+https://{self._username}:{self._password}"
                f"@{domain}:{self._port}"
                f"#{quote(remark)}"
            )
            links.append(ClientLink(
                uri=uri, protocol="naive", transport="h2",
                server_key=srv.key, remark=remark,
            ))
        return links

    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None:
        if not self._password:
            return None
        domain = self._domain or server.domain or server.host
        network = opts.get("network", "h2")
        return {
            "type": "naive",
            "tag": tag,
            "server": domain,
            "server_port": self._port,
            "username": self._username,
            "password": self._password,
            "network": network,
            "tls": {
                "enabled": True,
                "server_name": domain,
            },
        }
