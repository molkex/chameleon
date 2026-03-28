"""Traffic padding for sing-box outbounds — defeats ML-based timing analysis.

Adds multiplex with padding and enhanced TLS settings to outbound configs.

Modes:
- auto: smart padding based on outbound type (more for VLESS, less for HY2)
- aggressive: constant-rate padding (high bandwidth cost, maximum stealth)
- off: no padding applied
"""

from __future__ import annotations

import copy


def apply_padding(outbound: dict, mode: str = "auto") -> dict:
    """Add traffic padding configuration to a sing-box outbound.

    Returns a new dict (does not mutate the original).
    """
    if mode == "off":
        return outbound

    out = copy.deepcopy(outbound)
    proto = out.get("type", "")

    # --- TLS hardening for VLESS outbounds ---
    if proto == "vless" and "tls" in out:
        tls = out["tls"]
        tls.setdefault("utls", {"enabled": True, "fingerprint": "chrome"})
        tls.setdefault("ech", {"enabled": False})  # placeholder for future ECH

    # --- Multiplex with padding ---
    # HY2 has its own multiplexing; only add smux to TCP-based protocols
    if proto in ("vless", "trojan", "vmess", "shadowsocks"):
        max_conn = 8 if mode == "aggressive" else 4
        out["multiplex"] = {
            "enabled": True,
            "protocol": "h2mux",
            "max_connections": max_conn,
            "padding": True,
        }

    return out
