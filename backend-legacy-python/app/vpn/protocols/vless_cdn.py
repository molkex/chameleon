"""VLESS WebSocket CDN — Cloudflare-proxied fallback."""

from urllib.parse import quote

from app.config import get_settings

from .base import ClientLink, Protocol, ServerConfig, UserCredentials, XrayInbound

SNIFFING = {"enabled": True, "destOverride": ["http", "tls"]}
WS_PATH = "/vless-ws"


class VlessCdn(Protocol):
    def __init__(self) -> None:
        s = get_settings()
        self._port = s.vless_ws_port
        self._domain = s.cdn_domain  # Configured via CDN_DOMAIN env var
        self._path = WS_PATH

    @property
    def name(self) -> str:
        return "vless_cdn"

    @property
    def display_name(self) -> str:
        return "VLESS CDN"

    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        clients = [{"id": u.uuid, "email": f"{u.username}@ws"} for u in users]
        return [
            XrayInbound(
                tag="VLESS WS CDN",
                port=self._port,
                protocol="vless",
                settings={"clients": clients, "decryption": "none"},
                stream_settings={"network": "ws", "wsSettings": {"path": self._path}},
                sniffing=SNIFFING,
                listen="127.0.0.1",
            )
        ]

    def node_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        return []  # CDN only on master (behind nginx)

    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]:
        if not self._domain:
            return []  # CDN not configured
        uri = (
            f"vless://{user.uuid}@{self._domain}:443"
            f"?type=ws&security=tls&sni={self._domain}&host={self._domain}"
            f"&path={quote(self._path, safe='')}&fp=chrome"
            f"#{quote('CDN Fallback')}"
        )
        return [ClientLink(uri=uri, protocol="vless", transport="ws", server_key="cdn", remark="CDN Fallback")]

    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None:
        if not self._domain:
            return None  # CDN not configured
        return {
            "type": "vless",
            "tag": tag,
            "server": self._domain,
            "server_port": 443,
            "uuid": user.uuid,
            "tls": {"enabled": True, "server_name": self._domain, "utls": {"enabled": True, "fingerprint": "chrome"}},
            "transport": {"type": "ws", "path": self._path, "headers": {"Host": self._domain}},
            "multiplex": {
                "enabled": True,
                "protocol": "h2mux",
                "max_connections": 4,
                "padding": True,
            },
        }
