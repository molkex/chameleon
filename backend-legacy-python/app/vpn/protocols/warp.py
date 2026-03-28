"""WARP+ WireGuard — outbound-only protocol for routing blocked domains via Cloudflare.

WARP domain list loaded from data/warp_domains.json.
"""

import json
from functools import lru_cache
from pathlib import Path

from app.config import get_settings

from .base import ClientLink, Protocol, ServerConfig, UserCredentials, XrayInbound

WARP_PEER_PUBKEY = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

_DATA_FILE = Path(__file__).resolve().parent.parent / "data" / "warp_domains.json"


@lru_cache(maxsize=1)
def _load_warp_domains() -> list[str]:
    return json.loads(_DATA_FILE.read_text(encoding="utf-8"))["warp_domains"]


def __getattr__(name: str):
    if name == "WARP_DOMAINS":
        return _load_warp_domains()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


class Warp(Protocol):
    def __init__(self) -> None:
        s = get_settings()
        self._private_key = s.warp_private_key
        self._address_v4 = s.warp_address_v4
        self._address_v6 = s.warp_address_v6
        self._endpoint = s.warp_endpoint
        self._reserved = s.warp_reserved
        self._finalmask_mode = s.finalmask_mode

    @property
    def name(self) -> str:
        return "warp"

    @property
    def display_name(self) -> str:
        return "WARP+"

    @property
    def enabled(self) -> bool:
        return bool(self._private_key)

    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        return []  # Outbound-only

    def xray_outbounds(self) -> list[dict]:
        if not self._private_key:
            return [{"protocol": "blackhole", "tag": "WARP"}]

        ep_parts = self._endpoint.rsplit(":", 1)
        endpoint = f"{ep_parts[0]}:{ep_parts[1] if len(ep_parts) > 1 else 2408}"
        addresses = [self._address_v4]
        if self._address_v6:
            addresses.append(self._address_v6)

        outbound: dict = {
            "tag": "WARP",
            "protocol": "wireguard",
            "settings": {
                "secretKey": self._private_key,
                "address": addresses,
                "peers": [{
                    "publicKey": WARP_PEER_PUBKEY,
                    "allowedIPs": ["0.0.0.0/0", "::/0"],
                    "endpoint": endpoint,
                }],
                "reserved": self._reserved,
                "mtu": 1280,
                "domainStrategy": "ForceIP",
            },
        }
        # Finalmask obfuscation: make WireGuard traffic look like DNS/ICMP to DPI
        if self._finalmask_mode != "off":
            outbound["streamSettings"] = {
                "finalmask": {"type": self._finalmask_mode}
            }
        return [outbound]

    def xray_routing_rules(self) -> list[dict]:
        if not self._private_key:
            return []
        return [{"type": "field", "domain": _load_warp_domains(), "outboundTag": "WARP"}]

    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]:
        return []  # No client links — server-side routing only

    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None:
        if not self._private_key:
            return None
        ep_parts = self._endpoint.rsplit(":", 1)
        out: dict = {
            "type": "wireguard",
            "tag": tag,
            "private_key": self._private_key,
            "local_address": [self._address_v4],
            "peer_public_key": WARP_PEER_PUBKEY,
            "server": ep_parts[0],
            "server_port": int(ep_parts[1]) if len(ep_parts) > 1 else 2408,
            "reserved": self._reserved,
            "mtu": 1280,
        }
        if self._address_v6:
            out["local_address"].append(self._address_v6)
        return out
