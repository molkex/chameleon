"""
Shared auth dependencies for API v1 endpoints.
Supports session cookies (legacy/SPA), JWT tokens (API), and role-based access.

Roles:
  admin    — full access (manage admins, destructive ops)
  operator — manage VPN users, nodes, settings (no admin management)
  viewer   — read-only access to all dashboards and analytics
"""

import hashlib
import hmac
import ipaddress
import time
import logging

import bcrypt
import jwt
from fastapi import Request, HTTPException

from app.config import get_settings

logger = logging.getLogger(__name__)

# Session TTL: 8 hours
SESSION_TTL = 8 * 3600

# JWT config
JWT_ALGORITHM = "HS256"
JWT_ACCESS_TTL = 900       # 15 minutes
JWT_REFRESH_TTL = 7 * 86400  # 7 days

# Role hierarchy (higher value = more permissions)
ROLE_LEVELS = {"viewer": 1, "operator": 2, "admin": 3}


def hash_password(password: str) -> str:
    """Hash password with bcrypt (salt included automatically)."""
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(password: str, password_hash: str) -> bool:
    """Verify password against bcrypt hash. Falls back to SHA-256 for legacy hashes."""
    if password_hash.startswith("$2"):
        # bcrypt hash
        return bcrypt.checkpw(password.encode(), password_hash.encode())
    # Legacy SHA-256 (timing-safe comparison)
    legacy_hash = hashlib.sha256(password.encode()).hexdigest()
    return hmac.compare_digest(legacy_hash, password_hash)


def _get_jwt_secret() -> str:
    settings = get_settings()
    return settings.admin_jwt_secret


def create_access_token(user_id: int, username: str, role: str, ip: str | None = None) -> str:
    now = int(time.time())
    payload = {
        "sub": str(user_id),
        "username": username,
        "role": role,
        "iat": now,
        "exp": now + JWT_ACCESS_TTL,
        "type": "access",
    }
    if ip:
        payload["ip"] = ip
    return jwt.encode(payload, _get_jwt_secret(), algorithm=JWT_ALGORITHM)


def create_refresh_token(user_id: int, username: str, role: str, ip: str | None = None) -> str:
    now = int(time.time())
    payload = {
        "sub": str(user_id),
        "username": username,
        "role": role,
        "iat": now,
        "exp": now + JWT_REFRESH_TTL,
        "type": "refresh",
    }
    if ip:
        payload["ip"] = ip
    return jwt.encode(payload, _get_jwt_secret(), algorithm=JWT_ALGORITHM)


def _verify_jwt(token: str, token_type: str = "access", client_ip: str | None = None) -> dict | None:
    """Verify JWT token. Returns payload or None."""
    try:
        payload = jwt.decode(token, _get_jwt_secret(), algorithms=[JWT_ALGORITHM])
        if payload.get("type") != token_type:
            return None
        # IP binding check (optional — only if token was created with IP)
        if payload.get("ip") and client_ip and payload["ip"] != client_ip:
            logger.warning("JWT IP mismatch: token=%s, client=%s", payload["ip"], client_ip)
            return None
        return payload
    except jwt.ExpiredSignatureError:
        return None
    except jwt.InvalidTokenError:
        return None


def _check_session(request: Request) -> dict | None:
    """Check session-based auth with TTL enforcement.
    Returns session data dict (with role) or None.
    Marks session for DB revalidation every 5 minutes.
    """
    try:
        if not request.session.get("authenticated"):
            return None
        # Check session TTL
        login_at = request.session.get("login_at", 0)
        now = time.time()
        if now - login_at > SESSION_TTL:
            request.session.clear()
            logger.info("Session expired (TTL %ds)", SESSION_TTL)
            return None

        result = {
            "user_id": request.session.get("admin_user_id"),
            "username": request.session.get("admin_username", "unknown"),
            "role": request.session.get("admin_role", "viewer"),
        }

        # Mark for periodic DB revalidation (async caller should check)
        last_verified = request.session.get("_last_db_check", 0)
        result["_needs_db_check"] = (now - last_verified) > 300  # 5 min

        return result
    except Exception:
        return None


def _check_ip_allowlist(client_ip: str | None) -> None:
    """Reject admin requests from IPs not in the allowlist (if configured)."""
    settings = get_settings()
    if not settings.admin_ip_allowlist or not client_ip:
        return
    for allowed in settings.admin_ip_allowlist:
        try:
            network = ipaddress.ip_network(allowed, strict=False)
            if ipaddress.ip_address(client_ip) in network:
                return
        except ValueError:
            if client_ip == allowed:
                return
    logger.warning("Admin access denied for IP %s (not in allowlist)", client_ip)
    raise HTTPException(status_code=403, detail="IP not allowed")


async def get_current_admin(request: Request) -> dict:
    """Get current admin user info from session or JWT.

    Returns dict with keys: user_id, username, role.
    Raises HTTPException(401) if not authenticated.
    Raises HTTPException(403) if IP not in admin allowlist.
    """
    client_ip = request.client.host if request.client else None

    # Check IP allowlist before any auth
    _check_ip_allowlist(client_ip)

    # 1. Session auth (with periodic DB revalidation)
    session_data = _check_session(request)
    if session_data:
        if session_data.pop("_needs_db_check", False) and session_data.get("user_id"):
            try:
                from sqlalchemy import text
                from app.database.db import async_session
                async with async_session() as session:
                    row = await session.execute(
                        text("SELECT role, is_active FROM admin_users WHERE id = :id"),
                        {"id": session_data["user_id"]},
                    )
                    db_user = row.fetchone()
                    if db_user and db_user[1]:  # is_active
                        session_data["role"] = db_user[0]
                        request.session["admin_role"] = db_user[0]
                        request.session["_last_db_check"] = int(time.time())
                    elif db_user and not db_user[1]:  # deactivated
                        request.session.clear()
                        raise HTTPException(status_code=401, detail="Account deactivated")
            except HTTPException:
                raise
            except Exception:
                pass  # DB check best-effort
        return session_data

    # 2. JWT cookie
    jwt_cookie = request.cookies.get("access_token")
    if jwt_cookie:
        payload = _verify_jwt(jwt_cookie, "access", client_ip)
        if payload:
            return {
                "user_id": int(payload.get("sub", 0)),
                "username": payload.get("username", "unknown"),
                "role": payload.get("role", "viewer"),
            }

    # 3. Bearer token header
    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        token = auth_header[7:]
        payload = _verify_jwt(token, "access", client_ip)
        if payload:
            return {
                "user_id": int(payload.get("sub", 0)),
                "username": payload.get("username", "unknown"),
                "role": payload.get("role", "viewer"),
            }

    raise HTTPException(status_code=401, detail="Not authenticated")


async def require_auth(request: Request):
    """FastAPI dependency: require admin authentication (any role).
    Backwards-compatible — just checks auth, doesn't return user info.
    """
    await get_current_admin(request)


async def require_admin(request: Request) -> dict:
    """FastAPI dependency: require 'admin' role."""
    admin = await get_current_admin(request)
    if admin["role"] != "admin":
        raise HTTPException(status_code=403, detail="Admin role required")
    return admin


async def require_operator(request: Request) -> dict:
    """FastAPI dependency: require 'operator' or 'admin' role."""
    admin = await get_current_admin(request)
    level = ROLE_LEVELS.get(admin["role"], 0)
    if level < ROLE_LEVELS["operator"]:
        raise HTTPException(status_code=403, detail="Operator role required")
    return admin
