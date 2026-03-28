"""REST API v1: Protocols info endpoint."""

import logging

from fastapi import APIRouter, Depends

from app.vpn.protocols import registry
from app.auth.rbac import require_auth

logger = logging.getLogger(__name__)

router = APIRouter()


@router.get("/protocols")
async def api_protocols(_=Depends(require_auth)):
    """List registered VPN protocols from the plugin registry."""
    protocols = []
    for proto in registry.all():
        protocols.append({
            "name": proto.name,
            "display_name": proto.display_name,
            "enabled": proto.enabled,
        })
    return {"protocols": protocols}
