"""Node config pull endpoint — nodes fetch their xray config via authenticated HTTP.

Instead of SSH push, nodes can periodically GET /api/v1/node/config
to pull the latest xray config. Authentication is via a shared key
in the X-Node-Key header.
"""

import hashlib
import hmac
import json
import logging
import time

from fastapi import APIRouter, Header, HTTPException

from app.config import get_settings
from app.vpn import users as user_ops

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/node", tags=["node"])

# Lightweight config version — changes on every rebuild
_config_cache: dict = {"json": "", "version": "", "ts": 0}


def _verify_node_key(x_node_key: str) -> None:
    settings = get_settings()
    if not settings.node_api_key or len(settings.node_api_key) < 16:
        raise HTTPException(503, "Node API not configured (key missing or too short)")
    if not x_node_key or not hmac.compare_digest(x_node_key, settings.node_api_key):
        raise HTTPException(403, "Invalid node key")


@router.get("/config")
async def get_node_config(x_node_key: str = Header(...)):
    """Node pulls its xray config. Authenticated by shared key."""
    _verify_node_key(x_node_key)

    from app.database.db import get_session
    from app.vpn.engine import ChameleonEngine

    settings = get_settings()
    engine = ChameleonEngine(settings)

    async with get_session() as session:
        active = await user_ops.load_active_users(session)

    config = engine._build_node_config(active)
    config_json = json.dumps(config, separators=(",", ":"))
    version = hashlib.sha256(config_json.encode()).hexdigest()[:16]

    _config_cache.update(json=config_json, version=version, ts=int(time.time()))

    return {"config": config, "version": version}


@router.get("/health")
async def node_health(x_node_key: str = Header(...)):
    """Node reports health and gets current config version."""
    _verify_node_key(x_node_key)

    return {
        "status": "ok",
        "config_version": _config_cache.get("version", ""),
        "config_ts": _config_cache.get("ts", 0),
    }
