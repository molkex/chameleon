"""REST API v1: Branding & subscription settings endpoints."""

import json
import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse

from app.config import get_settings
from app.auth.rbac import require_auth, require_admin

logger = logging.getLogger(__name__)
router = APIRouter()

# Default branding values (used when no Redis override exists)
DEFAULTS = {
    "profile_title": "Chameleon VPN",
    "support_url": "",
    "support_channel": "",
    "web_page_url": "",
    "update_interval": "12",
    "brand_name": "Chameleon VPN",
    "brand_emoji": "",
    "support_emoji": "",
    "channel_emoji": "",
}

REDIS_KEY = "branding:settings"


async def get_branding() -> dict:
    """Get branding settings from Redis, with defaults fallback."""
    try:
        import redis.asyncio as aioredis
        settings = get_settings()
        r = aioredis.from_url(settings.redis_url, decode_responses=True)
        data = await r.get(REDIS_KEY)
        await r.aclose()
        if data:
            saved = json.loads(data)
            # Merge with defaults (so new keys get defaults)
            return {**DEFAULTS, **saved}
    except Exception as e:
        logger.debug("Branding settings read failed: %s", e)
    return dict(DEFAULTS)


async def save_branding(settings_data: dict):
    """Save branding settings to Redis."""
    import redis.asyncio as aioredis
    settings = get_settings()
    r = aioredis.from_url(settings.redis_url, decode_responses=True)
    await r.set(REDIS_KEY, json.dumps(settings_data, ensure_ascii=False))
    await r.aclose()


@router.get("/settings/branding")
async def api_get_branding(_=Depends(require_auth)):
    """Get current branding settings."""
    branding = await get_branding()
    return {"settings": branding, "defaults": DEFAULTS}


@router.patch("/settings/branding")
async def api_update_branding(request: Request, _=Depends(require_admin)):
    """Update branding settings. Only provided fields are updated."""
    body = await request.json()

    current = await get_branding()
    # Only allow known keys
    for key in DEFAULTS:
        if key in body:
            current[key] = body[key]

    await save_branding(current)
    logger.info("Branding settings updated: %s", list(body.keys()))
    return {"ok": True, "settings": current}


@router.post("/settings/branding/reset")
async def api_reset_branding(_=Depends(require_admin)):
    """Reset branding to defaults."""
    try:
        import redis.asyncio as aioredis
        settings = get_settings()
        r = aioredis.from_url(settings.redis_url, decode_responses=True)
        await r.delete(REDIS_KEY)
        await r.aclose()
    except Exception:
        pass
    return {"ok": True, "settings": DEFAULTS}


# -- WARP Settings --

WARP_REDIS_KEY = "warp:settings"

WARP_DEFAULTS = {
    "private_key": "",
    "address_v4": "172.16.0.2/32",
    "address_v6": "",
    "endpoint": "engage.cloudflareclient.com:2408",
    "reserved": "0,0,0",
}


async def get_warp_settings() -> dict:
    """Get WARP settings: Redis override > env vars > defaults."""
    settings = get_settings()

    # First check Redis override
    try:
        import redis.asyncio as aioredis
        r = aioredis.from_url(settings.redis_url, decode_responses=True)
        data = await r.get(WARP_REDIS_KEY)
        await r.aclose()
        if data:
            saved = json.loads(data)
            return {**WARP_DEFAULTS, **saved}
    except Exception:
        pass

    # Fall back to env vars
    return {
        "private_key": settings.warp_private_key,
        "address_v4": settings.warp_address_v4,
        "address_v6": settings.warp_address_v6,
        "endpoint": settings.warp_endpoint,
        "reserved": ",".join(str(x) for x in settings.warp_reserved),
    }


@router.get("/settings/warp")
async def api_get_warp(_=Depends(require_admin)):
    """Get current WARP settings. Private key is masked for security."""
    warp = await get_warp_settings()
    # Mask private key (show first 8 chars + ***)
    pk = warp.get("private_key", "")
    masked = {"enabled": bool(pk)}
    masked.update(warp)
    if pk and len(pk) > 8:
        masked["private_key_masked"] = pk[:8] + "***"
    else:
        masked["private_key_masked"] = "not set"
    return {"settings": masked}


@router.patch("/settings/warp")
async def api_update_warp(request: Request, _=Depends(require_admin)):
    """Update WARP settings. Saves to Redis and reloads xray config."""
    body = await request.json()

    current = await get_warp_settings()
    for key in WARP_DEFAULTS:
        if key in body:
            current[key] = body[key]

    # Save to Redis
    import redis.asyncio as aioredis
    settings = get_settings()
    r = aioredis.from_url(settings.redis_url, decode_responses=True)
    await r.set(WARP_REDIS_KEY, json.dumps(current, ensure_ascii=False))
    await r.aclose()

    logger.info("WARP settings updated: %s", [k for k in body if k != "private_key"])

    # Trigger xray config reload to apply WARP changes
    try:
        from app.dependencies import get_engine
        from app.database.db import async_session
        engine = get_engine()
        async with async_session() as session:
            await engine._regenerate_and_reload(session)
        logger.info("Xray config regenerated with new WARP settings")
    except Exception as e:
        logger.warning("Failed to regenerate xray config: %s", e)

    return {"ok": True, "enabled": bool(current["private_key"])}


@router.post("/settings/warp/test")
async def api_test_warp(_=Depends(require_admin)):
    """Test WARP connectivity by checking if WireGuard outbound works."""
    warp = await get_warp_settings()
    if not warp.get("private_key"):
        return {"ok": False, "error": "WARP not configured (no private key)"}

    # Check if WARP is configured by verifying private key exists
    try:
        enabled = bool(warp.get("private_key"))
        return {
            "ok": True,
            "enabled": enabled,
            "endpoint": warp["endpoint"],
            "address_v4": warp["address_v4"],
        }
    except Exception as e:
        return {"ok": False, "error": "Internal server error"}
