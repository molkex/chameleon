"""Mobile config — sing-box JSON for the app."""

from fastapi import APIRouter, Header, Query, Response

from app.vpn.config_version import get_config_version, make_config_headers

router = APIRouter()


@router.get("/config")
async def get_vpn_config(
    mode: str = Query("smart", pattern="^(smart|fullvpn|minimal)$"),
    if_none_match: str | None = Header(None),
):
    """Get sing-box JSON config. Supports ETag caching."""
    version = await get_config_version()

    # ETag: return 304 if client already has latest
    if if_none_match and if_none_match.strip('"') == version:
        return Response(status_code=304, headers=make_config_headers(version))

    # TODO: generate config based on authenticated user
    # For now, return placeholder
    return {"status": "not_implemented", "mode": mode}


@router.get("/servers")
async def get_servers():
    """Server list with health status."""
    from app.config import get_settings

    settings = get_settings()
    # TODO: add health data from Redis
    return {"servers": settings.vpn_servers}
