"""XICMP Tunnel — emergency fallback: proxy traffic over ICMP ping packets.

Even slower than XDNS but ICMP is almost never blocked by firewalls or DPI.
Uses xray Finalmask XICMP with mKCP transport wrapped in ICMP.

WARNING: LAST RESORT — extremely slow, unreliable on some networks.
Only enable when DNS tunnel also fails.
"""

from app.config import get_settings

from .base import ClientLink, Protocol, ServerConfig, UserCredentials, XrayInbound


class Xicmp(Protocol):
    def __init__(self) -> None:
        s = get_settings()
        self._enabled = s.xicmp_enabled

    @property
    def name(self) -> str:
        return "xicmp"

    @property
    def display_name(self) -> str:
        return "ICMP Tunnel (Emergency)"

    @property
    def enabled(self) -> bool:
        return self._enabled

    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        if not self.enabled:
            return []
        return [
            XrayInbound(
                tag="xicmp-in",
                port=0,  # ICMP is portless — raw socket
                protocol="dokodemo-door",
                settings={
                    "network": "tcp,udp",
                    "followRedirect": False,
                },
                stream_settings={
                    "network": "mkcp",
                    "kcpSettings": {
                        "header": {"type": "none"},
                        "seed": "",
                    },
                    "finalmask": {"type": "xicmp"},
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
                "tag": "xicmp-out",
                "streamSettings": {
                    "finalmask": {"type": "xicmp"},
                },
            }
        ]

    def xray_routing_rules(self) -> list[dict]:
        if not self.enabled:
            return []
        return [
            {
                "type": "field",
                "inboundTag": ["xicmp-in"],
                "outboundTag": "xicmp-out",
            }
        ]

    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]:
        """XICMP tunnel links — xray-native only."""
        if not self.enabled:
            return []
        links: list[ClientLink] = []
        for srv in servers:
            remark = f"{srv.flag} {srv.name} ICMP-Tunnel"
            uri = (
                f"xicmp://{user.uuid}@{srv.host}"
                f"?transport=mkcp"
                f"&security=none"
                f"#{remark}"
            )
            links.append(
                ClientLink(
                    uri=uri,
                    protocol="xicmp",
                    transport="icmp",
                    server_key=srv.key,
                    remark=remark,
                )
            )
        return links

    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None:
        # XICMP is NOT supported by sing-box — clients must use xray-based config
        return None
