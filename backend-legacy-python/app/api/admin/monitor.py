"""REST API v1: Monitor data -- resource checks + uptime charts."""

import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import select, func, desc

from app.database.db import async_session
from app.database.models import MonitorCheck
from app.utils import _fmt_msk
from app.auth.cache import cached
from app.auth.rbac import require_auth

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/monitor")
async def api_monitor(_=Depends(require_auth)):
    return await _get_monitor_data()


@cached("monitor", ttl=30)
async def _get_monitor_data() -> dict:
    now = datetime.now(timezone.utc)
    _24h = now - timedelta(hours=24)

    async with async_session() as session:
        # Latest checks per resource
        latest_sub = (
            select(
                MonitorCheck.resource,
                func.max(MonitorCheck.checked_at).label("max_ts"),
            )
            .group_by(MonitorCheck.resource)
            .subquery()
        )
        latest_q = await session.execute(
            select(MonitorCheck)
            .join(latest_sub, (
                (MonitorCheck.resource == latest_sub.c.resource) &
                (MonitorCheck.checked_at == latest_sub.c.max_ts)
            ))
            .order_by(MonitorCheck.resource)
        )
        checks = []
        for c in latest_q.scalars():
            checks.append({
                "resource": c.resource,
                "url": c.url or "",
                "is_available": bool(c.is_available),
                "response_time_ms": float(c.response_time_ms) if c.response_time_ms else None,
                "protocol": c.protocol or "",
                "checked_at": _fmt_msk(c.checked_at) if c.checked_at else "",
            })

        # Overall uptime (24h) -- 3 categories based on protocol/category
        uptime_vpn = await _calc_uptime(session, _24h, category="vpn")
        uptime_res = await _calc_uptime(session, _24h, category="residential")
        uptime_direct = await _calc_uptime(session, _24h, category="direct")

        # Hourly uptime charts
        hourly_vpn = await _hourly_uptime(session, _24h, category="vpn")
        hourly_res = await _hourly_uptime(session, _24h, category="residential")
        hourly_direct = await _hourly_uptime(session, _24h, category="direct")

    return {
        "checks": checks,
        "uptime_vpn": uptime_vpn,
        "uptime_residential": uptime_res,
        "uptime_direct": uptime_direct,
        "hourly_vpn": hourly_vpn,
        "hourly_residential": hourly_res,
        "hourly_direct": hourly_direct,
    }


async def _calc_uptime(session, since: datetime, category: str) -> float | None:
    """Calculate uptime percentage for a category in the given period."""
    total = (await session.execute(
        select(func.count(MonitorCheck.id)).where(
            MonitorCheck.checked_at >= since,
            MonitorCheck.category == category,
        )
    )).scalar_one()
    if total == 0:
        return None
    available = (await session.execute(
        select(func.count(MonitorCheck.id)).where(
            MonitorCheck.checked_at >= since,
            MonitorCheck.category == category,
            MonitorCheck.is_available == True,
        )
    )).scalar_one()
    return round(available / total * 100, 1)


async def _hourly_uptime(session, since: datetime, category: str) -> dict[str, float | None]:
    """Build hourly uptime map for the last 24h."""
    hour_col = func.date_trunc("hour", MonitorCheck.checked_at)
    q = await session.execute(
        select(
            hour_col.label("h"),
            func.count(MonitorCheck.id).label("total"),
            func.count(MonitorCheck.id).filter(MonitorCheck.is_available == True).label("ok"),
        )
        .where(
            MonitorCheck.checked_at >= since,
            MonitorCheck.category == category,
        )
        .group_by(hour_col)
        .order_by(hour_col)
    )
    result = {}
    for row in q.all():
        hour_key = row[0].strftime("%Y-%m-%d %H:00")
        total = row[1]
        ok = row[2]
        result[hour_key] = round(ok / total * 100, 1) if total > 0 else None
    return result
