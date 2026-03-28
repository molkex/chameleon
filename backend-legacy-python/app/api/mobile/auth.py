"""Mobile auth — Apple Sign In + device auth."""

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/auth")


class AppleAuthRequest(BaseModel):
    identity_token: str
    device_id: str | None = None


class DeviceAuthRequest(BaseModel):
    device_id: str


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int = 900  # 15 min


@router.post("/apple", response_model=TokenResponse)
async def auth_apple(req: AppleAuthRequest):
    """Sign in with Apple — verify identity token, issue JWT pair."""
    # TODO: verify with Apple JWKS, find/create user
    raise HTTPException(501, "Not implemented yet")


@router.post("/device", response_model=TokenResponse)
async def auth_device(req: DeviceAuthRequest):
    """Anonymous device auth — creates trial user."""
    # TODO: create user with device_id, issue JWT
    raise HTTPException(501, "Not implemented yet")


@router.post("/refresh", response_model=TokenResponse)
async def refresh_token(refresh_token: str):
    """Refresh access token."""
    raise HTTPException(501, "Not implemented yet")
