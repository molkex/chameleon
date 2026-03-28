"""REST API v1: Admin user management (RBAC). Admin-only endpoints."""

import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text

from app.database.db import async_session
from app.auth.rbac import require_admin, hash_password, ROLE_LEVELS

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/admins", tags=["admins"])

VALID_ROLES = list(ROLE_LEVELS.keys())


@router.get("")
async def list_admins(admin: dict = Depends(require_admin)):
    """List all admin users."""
    try:
        async with async_session() as session:
            result = await session.execute(
                text("SELECT id, username, role, is_active, last_login, created_at FROM admin_users ORDER BY id")
            )
            admins = []
            for row in result.fetchall():
                admins.append({
                    "id": row[0],
                    "username": row[1],
                    "role": row[2],
                    "is_active": row[3],
                    "last_login": row[4].isoformat() if row[4] else None,
                    "created_at": row[5].isoformat() if row[5] else None,
                })
            return admins
    except Exception as e:
        logger.exception("List admins failed: %s", e)
        return JSONResponse({"error": "Internal server error"}, status_code=500)


@router.post("")
async def create_admin_user(request: Request, admin: dict = Depends(require_admin)):
    """Create a new admin user. Body: {username, password, role}."""
    try:
        body = await request.json()
        username = body.get("username", "").strip()
        password = body.get("password", "")
        role = body.get("role", "viewer")

        if not username or not password:
            return JSONResponse({"error": "username and password required"}, status_code=400)
        if len(username) > 64:
            return JSONResponse({"error": "username too long (max 64)"}, status_code=400)
        if len(password) < 6:
            return JSONResponse({"error": "password too short (min 6)"}, status_code=400)
        if role not in VALID_ROLES:
            return JSONResponse({"error": f"invalid role, must be one of: {VALID_ROLES}"}, status_code=400)

        pw_hash = hash_password(password)

        async with async_session() as session:
            existing = await session.execute(
                text("SELECT id FROM admin_users WHERE username = :u"), {"u": username}
            )
            if existing.fetchone():
                return JSONResponse({"error": "username already exists"}, status_code=409)

            await session.execute(
                text("INSERT INTO admin_users (username, password_hash, role) VALUES (:u, :p, :r)"),
                {"u": username, "p": pw_hash, "r": role},
            )
            await session.commit()

            result = await session.execute(
                text("SELECT id, username, role, is_active, created_at FROM admin_users WHERE username = :u"),
                {"u": username},
            )
            row = result.fetchone()

        logger.info("Admin %s created user %s (role=%s)", admin["username"], username, role)
        return JSONResponse({
            "ok": True,
            "admin": {
                "id": row[0], "username": row[1], "role": row[2],
                "is_active": row[3], "created_at": row[4].isoformat() if row[4] else None,
            },
        }, status_code=201)

    except Exception as e:
        logger.exception("Create admin failed: %s", e)
        return JSONResponse({"error": "Internal server error"}, status_code=500)


@router.patch("/{admin_id}")
async def update_admin_user(admin_id: int, request: Request, admin: dict = Depends(require_admin)):
    """Update admin user. Body: optional {role, is_active, password}."""
    try:
        body = await request.json()

        updates = []
        params: dict = {"id": admin_id}

        if "role" in body:
            if body["role"] not in VALID_ROLES:
                return JSONResponse({"error": "invalid role"}, status_code=400)
            updates.append("role = :role")
            params["role"] = body["role"]

        if "is_active" in body:
            updates.append("is_active = :active")
            params["active"] = bool(body["is_active"])

        if "password" in body:
            if len(body["password"]) < 8:
                return JSONResponse({"error": "password too short (min 8)"}, status_code=400)
            if len(body["password"]) > 128:
                return JSONResponse({"error": "password too long (max 128)"}, status_code=400)
            updates.append("password_hash = :pw")
            params["pw"] = hash_password(body["password"])

        if not updates:
            return JSONResponse({"error": "no fields to update"}, status_code=400)

        # Prevent self-demotion
        if admin.get("user_id") == admin_id and "role" in body and body["role"] != "admin":
            return JSONResponse({"error": "cannot demote yourself"}, status_code=400)

        # Prevent self-deactivation
        if admin.get("user_id") == admin_id and "is_active" in body and not body["is_active"]:
            return JSONResponse({"error": "cannot deactivate yourself"}, status_code=400)

        async with async_session() as session:
            sql = f"UPDATE admin_users SET {', '.join(updates)} WHERE id = :id"
            result = await session.execute(text(sql), params)
            if result.rowcount == 0:
                return JSONResponse({"error": "admin not found"}, status_code=404)
            await session.commit()

        logger.info("Admin %s updated admin_id=%d: %s", admin["username"], admin_id, list(body.keys()))
        return {"ok": True}

    except Exception as e:
        logger.exception("Update admin failed: %s", e)
        return JSONResponse({"error": "Internal server error"}, status_code=500)


@router.delete("/{admin_id}")
async def delete_admin_user(admin_id: int, admin: dict = Depends(require_admin)):
    """Delete admin user. Cannot delete yourself."""
    try:
        if admin.get("user_id") == admin_id:
            return JSONResponse({"error": "cannot delete yourself"}, status_code=400)

        async with async_session() as session:
            result = await session.execute(
                text("DELETE FROM admin_users WHERE id = :id"), {"id": admin_id}
            )
            if result.rowcount == 0:
                return JSONResponse({"error": "admin not found"}, status_code=404)
            await session.commit()

        logger.info("Admin %s deleted admin_id=%d", admin["username"], admin_id)
        return {"ok": True}

    except Exception as e:
        logger.exception("Delete admin failed: %s", e)
        return JSONResponse({"error": "Internal server error"}, status_code=500)
