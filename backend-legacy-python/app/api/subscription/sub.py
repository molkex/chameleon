"""Public subscription endpoints: /sub/{token} and /sub/{token}/config.

These are unauthenticated — the token (vpn_username) acts as the secret.
"""

import logging

from fastapi import APIRouter, Header, Response
from fastapi.responses import JSONResponse

from app.config import get_settings
from app.database.db import async_session
from app.dependencies import get_redis
from app.vpn.user_service import UserService
from app.vpn.links import generate_all_links, format_subscription_text, get_subscription_headers
from app.vpn.singbox_config import generate_singbox_json
from app.vpn.config_version import get_config_version, make_config_headers
from app.vpn.protocols.base import ServerConfig

logger = logging.getLogger(__name__)

router = APIRouter()
_user_service = UserService()


def _build_servers() -> list[ServerConfig]:
    """Build server configs from settings."""
    settings = get_settings()
    configs = []
    for srv in settings.vpn_servers:
        configs.append(ServerConfig(
            host=srv.get("domain", srv["ip"]),
            port=settings.vless_tcp_port,
            domain=srv.get("domain", srv["ip"]),
            flag=srv["flag"],
            name=srv["name"],
            key=srv.get("domain", srv["ip"]).split(".")[0],
        ))
    return configs


@router.get("/{token}")
async def subscription(token: str):
    """Return subscription links in text format.
    Token is subscription_token (random hex), NOT vpn_username.
    """
    # Validate token format: min 32 hex chars
    if len(token) < 32 or not all(c in '0123456789abcdef' for c in token.lower()):
        return Response(content="Not found", status_code=404)

    redis = await get_redis()
    async with async_session() as session:
        sub_data = await _user_service.get_subscription_data_by_token(session, redis, token)

    if not sub_data:
        return Response(content="User not found", status_code=404)

    servers = _build_servers()
    creds = sub_data["credentials"]
    links = generate_all_links(creds, servers)
    text = format_subscription_text(links, sub_data["expire"])
    headers = get_subscription_headers(
        expire_ts=sub_data["expire"],
        upload=sub_data["upload"],
        download=sub_data["download"],
    )
    headers.update(make_config_headers(await get_config_version(), sub_data["expire"] or 0))

    return Response(content=text, media_type="text/plain", headers=headers)


@router.get("/{token}/config")
async def subscription_config(
    token: str,
    mode: str = "smart",
    if_none_match: str | None = Header(None),
):
    """Return sing-box JSON config with ETag caching."""
    # Check ETag for 304 Not Modified
    version = await get_config_version()
    if if_none_match and if_none_match.strip('"') == version:
        return Response(status_code=304)

    redis = await get_redis()
    async with async_session() as session:
        sub_data = await _user_service.get_subscription_data(session, redis, token)

    if not sub_data:
        return Response(content="User not found", status_code=404)

    servers = _build_servers()
    creds = sub_data["credentials"]
    config_json = generate_singbox_json(creds, servers, mode=mode)

    if not config_json:
        return JSONResponse({"error": "Failed to generate config"}, status_code=500)

    headers = make_config_headers(version, sub_data["expire"] or 0)
    headers["Cache-Control"] = "no-cache"

    return Response(content=config_json, media_type="application/json", headers=headers)
