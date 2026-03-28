"""ChameleonShield — server-controlled protocol priority and fallback."""

import json, time, logging
import redis.asyncio as aioredis
from app.config import get_settings

logger = logging.getLogger(__name__)

SHIELD_KEY = "chameleon:shield"
DEFAULT_PRIORITIES = {
    "vless_reality": {"priority": 1, "weight": 100, "status": "active"},
    "anytls": {"priority": 2, "weight": 90, "status": "active"},
    "vless_cdn": {"priority": 3, "weight": 80, "status": "active"},
    "naiveproxy": {"priority": 4, "weight": 70, "status": "active"},
    "hysteria2": {"priority": 5, "weight": 60, "status": "active"},
    "warp": {"priority": 10, "weight": 10, "status": "standby"},
}

async def get_shield_config() -> dict:
    """Get current protocol priorities. Admin can override via Redis."""
    settings = get_settings()
    try:
        r = aioredis.from_url(settings.redis_url, decode_responses=True)
        data = await r.get(SHIELD_KEY)
        await r.aclose()
        if data:
            return json.loads(data)
    except Exception:
        pass
    return DEFAULT_PRIORITIES

async def set_shield_config(config: dict):
    """Admin sets protocol priorities."""
    settings = get_settings()
    r = aioredis.from_url(settings.redis_url, decode_responses=True)
    await r.set(SHIELD_KEY, json.dumps(config))
    await r.aclose()

async def get_ordered_protocols() -> list[str]:
    """Return protocol names ordered by priority (lowest number = highest priority)."""
    config = await get_shield_config()
    active = [(name, info) for name, info in config.items() if info.get("status") == "active"]
    active.sort(key=lambda x: x[1].get("priority", 99))
    return [name for name, _ in active]

async def get_shield_response() -> dict:
    """API response for mobile app — priorities + recommended protocol + timestamp."""
    config = await get_shield_config()
    ordered = await get_ordered_protocols()
    return {
        "protocols": config,
        "recommended": ordered[0] if ordered else "vless_reality",
        "fallback_order": ordered,
        "updated_at": int(time.time()),
    }
