"""REST API v1: VPN user management endpoints."""

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from sqlalchemy import select, func, distinct, desc

from app.config import get_settings
from app.database.db import async_session
from app.database.models import User, Transaction, VpnTestResult
from app.utils import _fmt_msk, _MSK
from app.schemas.users import (
    VpnUserListResponse, VpnUserItem, VpnUserDetailResponse,
    VpnUserCreateRequest, VpnUserExtendRequest,
)
from app.dependencies import get_engine, get_redis
from app.auth.rbac import require_auth, require_operator

logger = logging.getLogger(__name__)

router = APIRouter()


@router.get("/users", response_model=VpnUserListResponse)
async def api_list_users(
    page: int = 1,
    page_size: int = 25,  # clamped below
    status: str | None = None,
    search: str | None = None,
    _=Depends(require_auth),
):
    """List VPN users with pagination and filtering."""
    page = max(1, page)
    page_size = max(1, min(200, page_size))
    offset = (page - 1) * page_size

    async with async_session() as session:
        query = select(User).where(User.vpn_uuid.isnot(None))

        if status == "active":
            query = query.where(
                User.is_active == True,
                User.subscription_expiry > datetime.now(timezone.utc),
            )
        elif status == "expired":
            query = query.where(User.subscription_expiry <= datetime.now(timezone.utc))
        elif status == "inactive":
            query = query.where(User.is_active == False)

        if search:
            # Escape SQL LIKE wildcards to prevent wildcard abuse
            safe_search = search.replace("%", r"\%").replace("_", r"\_")
            query = query.where(
                User.vpn_username.ilike(f"%{safe_search}%")
                | User.full_name.ilike(f"%{safe_search}%")
                | User.username.ilike(f"%{safe_search}%")
            )

        # Count
        count_q = select(func.count()).select_from(query.subquery())
        total = (await session.execute(count_q)).scalar_one()

        # Fetch page
        result = await session.execute(
            query.order_by(desc(User.created_at)).offset(offset).limit(page_size)
        )
        db_users = result.scalars().all()

        # Aggregate payment stats per user
        from app.database.models import ProxyClick
        user_ids = [u.id for u in db_users]
        payment_map = {}
        if user_ids:
            tx_q = select(
                Transaction.user_id,
                func.count(Transaction.id).label("cnt"),
                func.coalesce(func.sum(Transaction.amount), 0).label("total"),
            ).where(
                Transaction.user_id.in_(user_ids),
                Transaction.status == "paid",
            ).group_by(Transaction.user_id)
            for row in (await session.execute(tx_q)):
                payment_map[row.user_id] = {"count": row.cnt, "total": float(row.total)}

        # Proxy click counts
        click_map = {}
        if user_ids:
            click_q = select(
                ProxyClick.user_id,
                func.count(ProxyClick.id).label("cnt"),
            ).where(ProxyClick.user_id.in_(user_ids)).group_by(ProxyClick.user_id)
            for row in (await session.execute(click_q)):
                click_map[row.user_id] = row.cnt

    # Get traffic stats + device counts + violations in parallel
    from app.vpn.domain_parser import get_all_user_device_counts, get_device_violations
    from app.vpn import stats as vpn_stats
    try:
        traffic_stats, device_counts, violations = await asyncio.gather(
            vpn_stats.get_all_stats(),
            get_all_user_device_counts(),
            get_device_violations(),
        )
    except Exception:
        traffic_stats = {}
        device_counts = {}
        violations = {}
    user_apps: dict = {}

    settings = get_settings()
    global_limit = settings.max_devices_per_user

    users = []
    for u in db_users:
        traffic = traffic_stats.get(u.vpn_username, {})
        exp_fmt = None
        days_left = None
        if u.subscription_expiry:
            exp_msk = u.subscription_expiry.replace(tzinfo=timezone.utc).astimezone(_MSK)
            exp_fmt = exp_msk.strftime("%d.%m.%Y %H:%M")
            delta = u.subscription_expiry - datetime.now(timezone.utc)
            days_left = max(0, delta.days)

        dev_count = device_counts.get(u.vpn_username, 0)
        user_limit = getattr(u, "device_limit", None)
        exceeded = u.vpn_username in violations if u.vpn_username else False
        payments = payment_map.get(u.id, {"count": 0, "total": 0})

        users.append({
            "id": u.id,
            "username": getattr(u, "username", None),
            "full_name": getattr(u, "full_name", None),
            "vpn_username": u.vpn_username,
            "vpn_uuid": u.vpn_uuid,
            "is_active": u.is_active and (
                u.subscription_expiry is None or u.subscription_expiry > datetime.now(timezone.utc)
            ),
            "subscription_expiry": exp_fmt,
            "days_left": days_left,
            "plan": getattr(u, "current_plan", None),
            "traffic_up": round(traffic.get("up", 0) / 1024 / 1024 / 1024, 2),
            "traffic_down": round(traffic.get("down", 0) / 1024 / 1024 / 1024, 2),
            "cumulative_traffic": round((getattr(u, "cumulative_traffic", 0) or 0) / 1024 / 1024 / 1024, 2),
            "devices": dev_count,
            "device_limit": user_limit,
            "device_limit_exceeded": exceeded,
            "total_spent": payments["total"],
            "payment_count": payments["count"],
            "referral_count": 0,
            "ad_source": getattr(u, "ad_source", None),
            "proxy_clicks": click_map.get(u.id, 0),
            "detected_apps": user_apps.get(u.vpn_username, []),
            "created_at": _fmt_msk(u.created_at) if u.created_at else None,
        })

    return {
        "users": users,
        "total": total,
        "page": page,
        "page_size": page_size,
    }


@router.post("/users/{username}/extend")
async def api_extend_user(username: str, request: Request, _=Depends(require_operator)):
    """Extend a VPN user's subscription."""
    body = await request.json()
    days = body.get("days", 30)

    try:
        engine = get_engine()
        redis = await get_redis()
        async with async_session() as session:
            result = await engine.extend_user(session, redis, username, days=days)
        if result:
            logger.info("API: extended user %s by %d days", username, days)
            return JSONResponse({"ok": True, "username": username, "days": days})
        return JSONResponse({"ok": False, "error": "user not found"}, status_code=404)
    except Exception as e:
        logger.exception("API: extend user %s failed: %s", username, e)
        return JSONResponse({"ok": False, "error": "Internal server error"}, status_code=500)


@router.delete("/users/{username}")
async def api_delete_user(username: str, _=Depends(require_operator)):
    """Delete a VPN user."""
    try:
        engine = get_engine()
        redis = await get_redis()
        async with async_session() as session:
            await engine.delete_user(session, redis, username)
        logger.info("API: deleted user %s", username)
        return JSONResponse({"ok": True, "username": username})
    except Exception as e:
        logger.exception("API: delete user %s failed: %s", username, e)
        return JSONResponse({"ok": False, "error": "Internal server error"}, status_code=500)


@router.get("/users/{user_id}/detail", response_model=VpnUserDetailResponse)
async def api_user_detail(user_id: int, _=Depends(require_auth)):
    """Get detailed user info with transactions and tests."""
    async with async_session() as session:
        result = await session.execute(
            select(User).where(User.id == user_id)
        )
        user = result.scalar_one_or_none()
        if not user:
            return JSONResponse({"error": "user not found"}, status_code=404)

        # Transactions
        tx_result = await session.execute(
            select(Transaction)
            .where(Transaction.user_id == user.id)
            .order_by(desc(Transaction.created_at))
            .limit(20)
        )
        transactions = [
            {
                "amount": float(tx.amount or 0),
                "currency": tx.currency or "RUB",
                "status": tx.status,
                "date": _fmt_msk(tx.created_at) if tx.created_at else "",
            }
            for tx in tx_result.scalars()
        ]

        # VPN tests
        tests = []
        if user.vpn_username:
            test_result = await session.execute(
                select(VpnTestResult)
                .where(VpnTestResult.username == user.vpn_username)
                .order_by(desc(VpnTestResult.tested_at))
                .limit(5)
            )
            for t in test_result.scalars():
                tests.append({
                    "tested_at": _fmt_msk(t.tested_at) if t.tested_at else "",
                    "overall_score": getattr(t, "overall_score", None),
                })

    exp_fmt = None
    if user.subscription_expiry:
        exp_msk = user.subscription_expiry.replace(tzinfo=timezone.utc).astimezone(_MSK)
        exp_fmt = exp_msk.strftime("%d.%m.%Y %H:%M")

    # Get device info + UA info
    from app.vpn.domain_parser import get_user_devices
    from app.vpn.ua_tracker import get_user_ua_info
    devices = await get_user_devices(user.vpn_username) if user.vpn_username else {"ips": [], "count": 0}
    ua_info = await get_user_ua_info(user.vpn_username) if user.vpn_username else {"apps": [], "raw_uas": [], "app_count": 0}

    # Build subscription links
    sub_links = {}
    if user.vpn_username:
        sub_links = {
            "subscription": f"/sub/{user.vpn_username}",
            "smart": f"/sub/{user.vpn_username}/smart",
        }

    return {
        "user": {
            "id": user.id,
            "username": getattr(user, "username", None),
            "full_name": getattr(user, "full_name", None),
            "vpn_username": user.vpn_username,
            "vpn_uuid": user.vpn_uuid,
            "is_active": user.is_active,
            "subscription_expiry": exp_fmt,
            "plan": getattr(user, "current_plan", None),
            "traffic_up": 0,
            "traffic_down": 0,
            "devices": devices["count"],
            "ad_source": getattr(user, "ad_source", None),
            "created_at": _fmt_msk(user.created_at) if user.created_at else None,
        },
        "transactions": transactions,
        "referrals": [],
        "tests": tests,
        "devices": devices,
        "ua_info": ua_info,
        "sub_links": sub_links,
    }


@router.get("/users/{username}/devices")
async def api_user_devices(username: str, _=Depends(require_auth)):
    """Get device/IP tracking data for a VPN user."""
    from app.vpn.domain_parser import get_user_devices
    data = await get_user_devices(username)
    return data


@router.patch("/users/{username}/device-limit")
async def api_set_device_limit(username: str, request: Request, _=Depends(require_operator)):
    """Set device limit for a specific user. null = use global default, 0 = unlimited."""
    body = await request.json()
    limit = body.get("device_limit")  # int or null

    async with async_session() as session:
        result = await session.execute(
            select(User).where(User.vpn_username == username)
        )
        user = result.scalar_one_or_none()
        if not user:
            return JSONResponse({"ok": False, "error": "user not found"}, status_code=404)

        user.device_limit = limit
        await session.commit()
        logger.info("API: set device_limit=%s for %s", limit, username)
        return {"ok": True, "username": username, "device_limit": limit}


@router.get("/users/device-violations")
async def api_device_violations(_=Depends(require_auth)):
    """Get all users exceeding their device limit."""
    from app.vpn.domain_parser import get_device_violations
    violations = await get_device_violations()
    settings = get_settings()
    return {
        "violations": [
            {"username": k, **v} for k, v in violations.items()
        ],
        "global_limit": settings.max_devices_per_user,
    }
