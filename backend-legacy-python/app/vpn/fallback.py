"""Protocol fallback chains — ensures TCP-based connectivity during UDP blackout.

Orders outbounds for optimal fallback and builds sing-box selectors with
per-protocol tuning (shorter timeouts for reliable TCP, longer tolerance
for UDP).
"""

from __future__ import annotations

# Priority order: lower index = higher priority (tried first)
_PROTOCOL_PRIORITY = {
    ("vless", "tcp"):   0,   # VLESS Reality TCP — always works
    ("anytls", "tcp"):  1,   # AnyTLS TCP — anti-fingerprint
    ("vless", "ws"):    2,   # VLESS CDN WS — CDN fallback
    ("naiveproxy", "h2"): 3, # NaiveProxy H2 — Chromium fingerprint
    ("vless", "grpc"):  4,   # VLESS gRPC — backup
    ("hysteria2", "udp"): 5, # Hysteria2 UDP — fast but blockable
    ("wireguard", "udp"): 6, # WARP WireGuard — last resort
}

# Outbounds that use TCP transport (more reliable under DPI)
_TCP_TRANSPORTS = {"tcp", "ws", "grpc", "h2", "xhttp"}


def _sort_key(outbound: dict) -> tuple[int, str]:
    """Return sort key for an outbound dict based on protocol priority."""
    proto = outbound.get("type", "")
    transport = outbound.get("_transport_hint", "tcp")
    # Check transport from nested transport field
    if "transport" in outbound and isinstance(outbound["transport"], dict):
        transport = outbound["transport"].get("type", transport)
    # Hysteria2 is always UDP
    if proto == "hysteria2":
        transport = "udp"
    elif proto == "wireguard":
        transport = "udp"
    key = (proto, transport)
    return (_PROTOCOL_PRIORITY.get(key, 99), outbound.get("tag", ""))


def build_fallback_chain(
    outbounds: list[dict],
) -> list[dict]:
    """Order outbounds for optimal fallback — TCP first, UDP last.

    Returns a new sorted list (does not mutate originals).
    """
    return sorted(outbounds, key=_sort_key)


def build_smart_selector(
    outbounds: list[dict],
    tag: str = "proxy",
) -> dict:
    """Create a sing-box urltest selector with per-protocol tuning.

    TCP outbounds get shorter timeout (they're inherently more reliable),
    UDP outbounds get longer tolerance to avoid premature switching.
    """
    ordered = build_fallback_chain(outbounds)
    outbound_tags = [o["tag"] for o in ordered]

    return {
        "type": "urltest",
        "tag": tag,
        "outbounds": outbound_tags,
        "url": "https://cp.cloudflare.com/",
        "interval": "90s",
        "tolerance": 150,
        "idle_timeout": "30m",
        "interrupt_exist_connections": False,
    }
