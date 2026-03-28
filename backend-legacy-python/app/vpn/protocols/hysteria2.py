"""Hysteria2 — UDP-based protocol (runs as separate binary, no xray inbound).

Supports FinalMask UDP obfuscation modes:
- salamander: default obfs (built-in to hy2)
- xdns: mask UDP as DNS traffic (xray-level, post-transport)
- xicmp: mask UDP as ICMP traffic (xray-level, post-transport)
- off: no FinalMask obfuscation
"""

from urllib.parse import quote

from app.config import get_settings

from .base import ClientLink, Protocol, ServerConfig, UserCredentials, XrayInbound

# FinalMask modes that require xray-level outbound wrapping
_FINALMASK_XRAY_MODES = {"xdns", "xicmp"}


class Hysteria2(Protocol):
    def __init__(self) -> None:
        s = get_settings()
        self._password = s.hy2_password
        self._obfs_password = s.hy2_obfs_password
        self._port = s.hysteria2_port
        self._finalmask_mode = s.finalmask_mode

    @property
    def name(self) -> str:
        return "hysteria2"

    @property
    def display_name(self) -> str:
        return "Hysteria2"

    @property
    def enabled(self) -> bool:
        return bool(self._password)

    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        return []  # Separate binary, not xray

    def xray_outbounds(self) -> list[dict]:
        """Return FinalMask obfuscation outbound when xdns/xicmp mode is active.

        FinalMask is applied at the xray level (post-transport) to mask
        UDP packets leaving the server, making Hysteria2 traffic look like
        DNS or ICMP to DPI systems.
        """
        if self._finalmask_mode not in _FINALMASK_XRAY_MODES:
            return []
        return [
            {
                "protocol": "freedom",
                "tag": "hy2-finalmask",
                "streamSettings": {
                    "finalmask": {
                        "type": self._finalmask_mode,
                    }
                },
            }
        ]

    def xray_routing_rules(self) -> list[dict]:
        """Route Hysteria2 traffic through FinalMask outbound when active."""
        if self._finalmask_mode not in _FINALMASK_XRAY_MODES:
            return []
        return [
            {
                "type": "field",
                "inboundTag": ["hy2-in"],
                "outboundTag": "hy2-finalmask",
            }
        ]

    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]:
        if not self._password:
            return []
        links: list[ClientLink] = []
        for srv in servers:
            remark = f"{srv.flag} {srv.name} Hysteria2"
            uri = (
                f"hy2://{self._password}@{srv.host}:{self._port}"
                f"?insecure=1&sni=rutube.ru&obfs=salamander"
                f"&obfs-password={self._obfs_password}"
                f"#{quote(remark)}"
            )
            links.append(ClientLink(uri=uri, protocol="hysteria2", transport="udp", server_key=srv.key, remark=remark))
        return links

    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None:
        if not self._password:
            return None
        return {
            "type": "hysteria2",
            "tag": tag,
            "server": server.host,
            "server_port": self._port,
            "password": self._password,
            "tls": {"enabled": True, "server_name": "rutube.ru", "insecure": True},
            "obfs": {"type": "salamander", "password": self._obfs_password},
        }
