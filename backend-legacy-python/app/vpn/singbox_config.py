"""sing-box JSON config generator for Chameleon VPN.

Supports sing-box 1.13+ format.  The native iOS/macOS app handles routing
preferences client-side; the server only provides:

- generate_singbox_json(user, servers, mode)  -- full sing-box config
- generate_subscription_links(user, servers)  -- VLESS/HY2 URIs for /sub/
"""

import json
import logging

from app.vpn.antiblock_config import BLOCKED_DOMAINS
from app.vpn.protocols import registry
from app.vpn.protocols.base import ServerConfig, UserCredentials

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BLOCKED_DOMAIN_SUFFIXES = [
    d.replace("domain:", "") for d in BLOCKED_DOMAINS if d.startswith("domain:")
]

HEALTH_CHECK_URL = "https://www.gstatic.com/generate_204"

TUN_INBOUND = {
    "type": "tun",
    "tag": "tun-in",
    "address": ["172.18.0.1/30", "fdfe:dcba:9876::1/126"],
    "mtu": 1400,
    "auto_route": True,
    "strict_route": True,
    "stack": "mixed",
}

DIRECT_OUTBOUND = {"type": "direct", "tag": "direct", "udp_fragment": True}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _build_outbounds(
    user: UserCredentials,
    servers: list[ServerConfig],
) -> list[dict]:
    """Build outbound list by iterating all enabled protocols in the registry."""
    outbounds: list[dict] = []
    for proto in registry.enabled():
        for srv in servers:
            tag = f"{srv.key}-{proto.name}"
            ob = proto.singbox_outbound(tag, srv, user)
            if ob:
                outbounds.append(ob)
    return outbounds


def _assemble_config(
    outbounds: list[dict],
    mode: str = "smart",
) -> dict:
    """Wrap outbounds into a complete sing-box config."""
    all_tags = [o["tag"] for o in outbounds]

    # urltest selector over all proxy outbounds
    auto_group = {
        "type": "urltest",
        "tag": "auto",
        "outbounds": all_tags,
        "url": HEALTH_CHECK_URL,
        "interval": "3m",
        "tolerance": 200,
    }

    # Selector: auto + individual + direct
    selector = {
        "type": "selector",
        "tag": "proxy",
        "outbounds": ["auto", *all_tags, "direct"],
        "default": "auto",
    }

    # DNS
    dns_servers = [
        {
            "tag": "dns-proxy",
            "type": "https",
            "server": "1.1.1.1",
            "server_port": 443,
            "path": "/dns-query",
            "detour": "auto",
        },
        {
            "tag": "dns-direct",
            "type": "https",
            "server": "77.88.8.8",
            "server_port": 443,
            "path": "/dns-query",
            "detour": "direct",
        },
        {
            "tag": "dns-resolver",
            "type": "udp",
            "server": "77.88.8.8",
            "server_port": 53,
            "detour": "direct",
        },
    ]

    dns_rules: list[dict] = [
        {"outbound": "any", "action": "route", "server": "dns-resolver"},
    ]
    if BLOCKED_DOMAIN_SUFFIXES:
        dns_rules.append(
            {"domain_suffix": BLOCKED_DOMAIN_SUFFIXES, "action": "route", "server": "dns-proxy"},
        )

    # Route rules
    route_rules: list[dict] = [
        {"action": "sniff"},
        {"protocol": "dns", "action": "hijack-dns"},
        {"ip_is_private": True, "action": "route", "outbound": "direct"},
    ]
    if BLOCKED_DOMAIN_SUFFIXES:
        route_rules.append(
            {"domain_suffix": BLOCKED_DOMAIN_SUFFIXES, "action": "reject"},
        )

    # Mode determines where unmatched traffic goes
    if mode == "fullvpn":
        final_outbound = "proxy"
        dns_final = "dns-proxy"
    else:
        # smart: only blocked domains through proxy, rest direct
        final_outbound = "direct"
        dns_final = "dns-direct"

    return {
        "log": {"level": "warn", "timestamp": True},
        "dns": {"servers": dns_servers, "rules": dns_rules, "final": dns_final},
        "inbounds": [TUN_INBOUND],
        "outbounds": [selector, auto_group, *outbounds, DIRECT_OUTBOUND],
        "route": {
            "rules": route_rules,
            "final": final_outbound,
            "auto_detect_interface": True,
        },
        "experimental": {
            "cache_file": {"enabled": True, "path": "cache.db"},
        },
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def generate_singbox_config(
    user: UserCredentials,
    servers: list[ServerConfig],
    mode: str = "smart",
) -> dict | None:
    """Generate a sing-box JSON config dict.

    Args:
        user: VPN user credentials (uuid, short_id, username).
        servers: Available VPN server configs.
        mode: "smart" (selective) or "fullvpn" (all traffic proxied).

    Returns:
        Complete sing-box config dict, or None if no outbounds could be built.
    """
    outbounds = _build_outbounds(user, servers)
    if not outbounds:
        logger.error("generate_singbox_config: no outbounds from registry")
        return None
    return _assemble_config(outbounds, mode)


def generate_singbox_json(
    user: UserCredentials,
    servers: list[ServerConfig],
    mode: str = "smart",
) -> str | None:
    """Generate sing-box config as formatted JSON string."""
    config = generate_singbox_config(user, servers, mode)
    if not config:
        return None
    return json.dumps(config, indent=2, ensure_ascii=False)
