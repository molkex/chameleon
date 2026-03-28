"""XDNS Tunnel — emergency fallback: proxy traffic over DNS queries.

When TCP and UDP are both blocked, DNS (port 53) usually stays open.
Uses xray Finalmask XDNS to tunnel data inside DNS packets.

WARNING: This is a LAST RESORT protocol — very slow, small MTU (~512 bytes).
Only enable when all other transports are blocked.
"""

from app.config import get_settings

from .base import ClientLink, Protocol, ServerConfig, UserCredentials, XrayInbound


class Xdns(Protocol):
    def __init__(self) -> None:
        s = get_settings()
        self._domain = s.xdns_domain
        self._enabled = s.xdns_enabled

    @property
    def name(self) -> str:
        return "xdns"

    @property
    def display_name(self) -> str:
        return "DNS Tunnel (Emergency)"

    @property
    def enabled(self) -> bool:
        return self._enabled and bool(self._domain)

    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        if not self.enabled:
            return []
        return [
            XrayInbound(
                tag="xdns-in",
                port=53,
                protocol="dokodemo-door",
                settings={
                    "network": "udp",
                    "followRedirect": False,
                },
                stream_settings={
                    "finalmask": {"type": "xdns"},
                },
                sniffing={"enabled": True, "destOverride": ["http", "tls"]},
            )
        ]

    def xray_outbounds(self) -> list[dict]:
        if not self.enabled:
            return []
        return [
            {
                "protocol": "freedom",
                "tag": "xdns-out",
                "streamSettings": {
                    "finalmask": {"type": "xdns"},
                },
            }
        ]

    def xray_routing_rules(self) -> list[dict]:
        if not self.enabled:
            return []
        return [
            {
                "type": "field",
                "inboundTag": ["xdns-in"],
                "outboundTag": "xdns-out",
            }
        ]

    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]:
        """XDNS tunnel links — xray-native only, not sing-box compatible."""
        if not self.enabled:
            return []
        links: list[ClientLink] = []
        for srv in servers:
            remark = f"{srv.flag} {srv.name} DNS-Tunnel"
            # xdns:// is an xray-native URI scheme for Finalmask XDNS
            uri = (
                f"xdns://{user.uuid}@{self._domain}:53"
                f"?domain={self._domain}"
                f"&security=none"
                f"#{remark}"
            )
            links.append(
                ClientLink(
                    uri=uri,
                    protocol="xdns",
                    transport="dns",
                    server_key=srv.key,
                    remark=remark,
                )
            )
        return links

    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None:
        # XDNS is NOT supported by sing-box — clients must use xray-based config
        return None
