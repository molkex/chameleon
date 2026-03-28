"""Config versioning — clients skip refresh when config hasn't changed."""

import hashlib, json, time
import redis.asyncio as aioredis
from app.config import get_settings

VERSION_KEY = "chameleon:config_version"

async def get_config_version() -> str:
    """Get current config version hash."""
    settings = get_settings()
    try:
        r = aioredis.from_url(settings.redis_url, decode_responses=True)
        version = await r.get(VERSION_KEY)
        await r.aclose()
        return version or "0"
    except Exception:
        return "0"

async def update_config_version(config_data: dict | str = None):
    """Update version hash. Called after any config change (user add/delete, protocol change)."""
    settings = get_settings()
    if config_data:
        raw = json.dumps(config_data, sort_keys=True) if isinstance(config_data, dict) else config_data
        version = hashlib.sha256(raw.encode()).hexdigest()[:12]
    else:
        version = hashlib.sha256(str(time.time()).encode()).hexdigest()[:12]

    r = aioredis.from_url(settings.redis_url, decode_responses=True)
    await r.set(VERSION_KEY, version)
    await r.aclose()
    return version

def make_config_headers(version: str, expire_ts: int = 0) -> dict:
    """Add version headers to subscription response."""
    headers = {"X-Config-Version": version, "ETag": f'"{version}"'}
    if expire_ts:
        headers["X-Subscription-Expiry"] = str(expire_ts)
    return headers
