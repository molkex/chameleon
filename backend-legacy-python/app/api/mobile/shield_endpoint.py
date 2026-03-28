"""ChameleonShield API — protocol priorities for the app."""

from fastapi import APIRouter

from app.vpn.shield import get_shield_response

router = APIRouter()


@router.get("/shield")
async def get_shield():
    """Get protocol priorities and recommended protocol."""
    return await get_shield_response()
