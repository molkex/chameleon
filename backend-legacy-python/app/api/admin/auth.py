"""
JWT auth endpoints for API v1.
- POST /api/v1/auth/login — authenticate, return JWT tokens in httpOnly cookies
- POST /api/v1/auth/refresh — rotate access token using refresh cookie
- POST /api/v1/auth/logout — clear JWT cookies
- GET  /api/v1/auth/me — current user info (username, role)
"""

import logging

from fastapi import APIRouter, Request, HTTPException, Depends
from fastapi.responses import JSONResponse

from app.auth.rbac import (
    create_access_token,
    create_refresh_token,
    _verify_jwt,
    get_current_admin,
    JWT_ACCESS_TTL,
    JWT_REFRESH_TTL,
)

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/auth", tags=["auth"])


def _set_token_cookies(response: JSONResponse, access: str, refresh: str) -> JSONResponse:
    response.set_cookie(
        "access_token", access,
        max_age=JWT_ACCESS_TTL,
        httponly=True, secure=True, samesite="strict",
    )
    response.set_cookie(
        "refresh_token", refresh,
        max_age=JWT_REFRESH_TTL,
        httponly=True, secure=True, samesite="strict",
        path="/api/v1/admin/auth",  # only sent to auth endpoints
    )
    return response


@router.post("/login")
async def jwt_login(request: Request):
    """Authenticate with username/password, return JWT tokens."""
    body = await request.json()
    username = body.get("username", "")
    password = body.get("password", "")
    client_ip = request.client.host if request.client else None

    from app.auth.admin_auth import _authenticate_admin
    admin = await _authenticate_admin(username, password)
    if not admin:
        raise HTTPException(status_code=401, detail="Invalid credentials")

    user_id = admin["id"] or 0
    role = admin["role"]

    access = create_access_token(user_id, admin["username"], role, ip=client_ip)
    refresh = create_refresh_token(user_id, admin["username"], role, ip=client_ip)

    response = JSONResponse({
        "ok": True,
        "expires_in": JWT_ACCESS_TTL,
        "user": {"id": user_id, "username": admin["username"], "role": role},
    })
    _set_token_cookies(response, access, refresh)

    logger.info("JWT login: %s (role=%s) from %s", admin["username"], role, client_ip)
    from app.auth.admin_auth import _audit_log
    await _audit_log("jwt_login", client_ip or "unknown",
                     request.headers.get("user-agent"),
                     f"user={admin['username']} role={role}",
                     admin_user_id=admin["id"])

    return response


@router.post("/refresh")
async def jwt_refresh(request: Request):
    """Rotate access token using refresh cookie. One-time-use via Redis."""
    import hashlib
    from app.dependencies import get_redis

    client_ip = request.client.host if request.client else None

    refresh_cookie = request.cookies.get("refresh_token")
    if not refresh_cookie:
        raise HTTPException(status_code=401, detail="No refresh token")

    payload = _verify_jwt(refresh_cookie, "refresh", client_ip)
    if not payload:
        raise HTTPException(status_code=401, detail="Invalid or expired refresh token")

    user_id = int(payload.get("sub", 0))
    username = payload.get("username", "unknown")
    role = payload.get("role", "viewer")
    if not username or role not in ("admin", "operator", "viewer"):
        raise HTTPException(status_code=401, detail="Invalid token claims")

    # One-time-use: atomic SETNX in Redis (fail-closed)
    token_hash = hashlib.sha256(refresh_cookie.encode()).hexdigest()
    blacklist_key = f"refresh_used:{token_hash}"
    try:
        redis = await get_redis()
        was_new = await redis.set(blacklist_key, "1", ex=JWT_REFRESH_TTL, nx=True)
        if not was_new:
            logger.warning("Refresh token replay detected: user=%s", username)
            raise HTTPException(status_code=401, detail="Token already used")
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Redis unavailable for token blacklist — failing closed: %s", e)
        raise HTTPException(status_code=503, detail="Service temporarily unavailable")

    # Re-verify user is still active in DB
    try:
        from app.auth.admin_auth import _authenticate_admin
        from app.database.db import async_session
        from sqlalchemy import text
        async with async_session() as session:
            result = await session.execute(
                text("SELECT role, is_active FROM admin_users WHERE id = :id"),
                {"id": user_id},
            )
            row = result.fetchone()
            if row:
                if not row[1]:  # is_active = False
                    raise HTTPException(status_code=401, detail="Account deactivated")
                role = row[0]  # Use current DB role, not stale JWT role
    except HTTPException:
        raise
    except Exception:
        pass  # DB check is best-effort, don't block refresh

    # Issue new tokens
    access = create_access_token(user_id, username, role, ip=client_ip)
    refresh = create_refresh_token(user_id, username, role, ip=client_ip)

    response = JSONResponse({
        "ok": True,
        "expires_in": JWT_ACCESS_TTL,
        "user": {"id": user_id, "username": username, "role": role},
    })
    _set_token_cookies(response, access, refresh)
    return response


@router.post("/logout")
async def jwt_logout(request: Request):
    """Clear JWT cookies."""
    response = JSONResponse({"ok": True})
    response.delete_cookie("access_token")
    response.delete_cookie("refresh_token", path="/api/v1/admin/auth")
    return response


@router.get("/me")
async def get_me(admin: dict = Depends(get_current_admin)):
    """Get current authenticated admin user info."""
    return {
        "id": admin.get("user_id"),
        "username": admin["username"],
        "role": admin["role"],
    }
