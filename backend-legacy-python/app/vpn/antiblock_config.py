"""Blocked domain list and VLESS link parser.

Domain data loaded from data/blocked_domains.json.
"""

import json
import logging
from functools import lru_cache
from pathlib import Path
from urllib.parse import parse_qs, unquote

logger = logging.getLogger(__name__)

_DATA_FILE = Path(__file__).parent / "data" / "blocked_domains.json"


@lru_cache(maxsize=1)
def _load_blocked() -> list[str]:
    return json.loads(_DATA_FILE.read_text(encoding="utf-8"))["blocked_domains"]


# Module-level constant — lazy-loaded on first access via __getattr__
def __getattr__(name: str):
    if name == "BLOCKED_DOMAINS":
        return _load_blocked()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def parse_vless_link(link: str) -> dict | None:
    """Parse a VLESS URI into connection parameters."""
    if not link.startswith("vless://"):
        return None

    try:
        rest = link[len("vless://"):]

        remark = ""
        if "#" in rest:
            rest, remark = rest.rsplit("#", 1)
            remark = unquote(remark)

        params = {}
        if "?" in rest:
            rest, qs = rest.split("?", 1)
            params = {k: v[0] for k, v in parse_qs(qs).items()}

        uuid_part, hostport = rest.split("@", 1)
        if ":" in hostport:
            host, port = hostport.rsplit(":", 1)
            port = int(port)
        else:
            host = hostport
            port = 443

        return {
            "uuid": uuid_part,
            "host": host,
            "port": port,
            "remark": remark,
            "type": params.get("type", "tcp"),
            "security": params.get("security", ""),
            "sni": params.get("sni", ""),
            "fingerprint": params.get("fp", "chrome"),
            "public_key": params.get("pbk", ""),
            "short_id": params.get("sid", ""),
            "flow": params.get("flow", ""),
        }
    except Exception as e:
        logger.warning("Failed to parse VLESS link: %s", e)
        return None
