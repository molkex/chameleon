"""AnyTLS — defeats TLS-in-TLS fingerprinting (Aparecium-proof).

Multiplexes streams inside a single TLS connection with controlled padding.
Runs as separate binary or sing-box inbound, NOT xray.
"""

from urllib.parse import quote

from app.config import get_settings

from .base import ClientLink, Protocol, ServerConfig, UserCredentials, XrayInbound


class AnyTLS(Protocol):
    def __init__(self) -> None:
        s = get_settings()
        self._port = s.anytls_port
        self._password = s.anytls_password
        self._sni = s.anytls_sni

    @property
    def name(self) -> str:
        return "anytls"

    @property
    def display_name(self) -> str:
        return "AnyTLS"

    @property
    def enabled(self) -> bool:
        return bool(self._password)

    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        return []  # AnyTLS is not an xray protocol

    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]:
        links: list[ClientLink] = []
        for srv in servers:
            host = srv.domain or srv.host
            remark = f"{srv.flag} {srv.name} AnyTLS"
            uri = (
                f"anytls://{self._password}@{host}:{self._port}"
                f"?sni={self._sni}"
                f"#{quote(remark)}"
            )
            links.append(ClientLink(
                uri=uri, protocol="anytls", transport="tcp",
                server_key=srv.key, remark=remark,
            ))
        return links

    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None:
        if not self._password:
            return None
        return {
            "type": "anytls",
            "tag": tag,
            "server": server.domain or server.host,
            "server_port": self._port,
            "password": self._password,
            "idle_timeout": "15m",
            "tls": {
                "enabled": True,
                "server_name": self._sni,
            },
        }
