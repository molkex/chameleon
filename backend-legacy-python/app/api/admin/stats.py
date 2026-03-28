"""REST API v1: Dashboard & analytics stats endpoints."""

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import select, func, distinct, case as sa_case

from app.database.db import async_session
from app.database.models import User, Transaction, ProxyClick, AnalyticsEvent, MonitorCheck
from app.utils import _fmt_msk, _MSK
from app.auth.cache import cached
from app.schemas.stats import (
    DashboardResponse, DashboardStats, VpnStats,
    ExpiringUser, RecentTransaction, ExpiryCalendarPoint,
    FunnelResponse, FunnelStage, FunnelDayData,
)
from app.dependencies import get_engine
from app.database.db import async_session
from app.auth.rbac import require_auth

logger = logging.getLogger(__name__)

router = APIRouter()


@router.get("/stats/dashboard", response_model=DashboardResponse)
async def api_dashboard(_=Depends(require_auth)):
    """Get dashboard KPIs, revenue chart, recent transactions."""
    data = await _get_dashboard_data()
    return data


@cached("dashboard:data", ttl=30)
async def _get_dashboard_data() -> dict:
    """Fetch all dashboard data (cached 30s)."""
    stats = {}
    recent_transactions = []
    now_utc = datetime.now(timezone.utc)
    today_start = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)

    async with async_session() as session:
        res = await session.execute(select(func.count(User.id)))
        stats["total_users"] = res.scalar_one()

        res = await session.execute(select(func.count(User.id)).where(User.is_active == True))
        stats["active_users"] = res.scalar_one()

        # Reachable users (not blocked the bot)
        res = await session.execute(
            select(func.count(User.id)).where(User.bot_blocked_at.isnot(None))
        )
        blocked = res.scalar_one()
        stats["blocked_users"] = blocked
        stats["reachable_users"] = stats["total_users"] - blocked

        res = await session.execute(
            select(func.count(User.id)).where(User.created_at >= today_start)
        )
        stats["today_new"] = res.scalar_one()

        # Revenue by currency
        res = await session.execute(
            select(Transaction.currency, func.sum(Transaction.amount))
            .where(Transaction.status == "paid")
            .group_by(Transaction.currency)
        )
        revenue_by_currency = {}
        for row in res:
            currency, total = row
            if currency and total:
                revenue_by_currency[currency] = float(total)
        stats["revenue_by_currency"] = revenue_by_currency

        # Today revenue
        res = await session.execute(
            select(Transaction.currency, func.sum(Transaction.amount))
            .where(Transaction.status == "paid", Transaction.created_at >= today_start)
            .group_by(Transaction.currency)
        )
        today_revenue = {}
        for row in res:
            currency, total = row
            if currency and total:
                today_revenue[currency] = float(total)
        stats["today_revenue"] = today_revenue

        # Transaction counts
        res = await session.execute(
            select(func.count(Transaction.id)).where(Transaction.created_at >= today_start)
        )
        stats["today_transactions"] = res.scalar_one()

        res = await session.execute(
            select(func.count(Transaction.id)).where(
                Transaction.created_at >= today_start, Transaction.status == "paid"
            )
        )
        stats["today_paid"] = res.scalar_one()

        res = await session.execute(select(func.count(ProxyClick.id)))
        stats["proxy_clicks"] = res.scalar_one()

        # Conversion 30d
        _30d_ago = now_utc - timedelta(days=30)
        res = await session.execute(
            select(func.count(User.id)).where(User.created_at >= _30d_ago)
        )
        new_30d = res.scalar_one() or 0
        res = await session.execute(
            select(func.count(distinct(Transaction.user_id)))
            .join(User, User.id == Transaction.user_id)
            .where(Transaction.status == "paid", User.created_at >= _30d_ago)
        )
        paying_30d = res.scalar_one() or 0
        stats["conversion_30d"] = round(paying_30d / new_30d * 100, 1) if new_30d > 0 else 0

        # Churn 7d
        _7d_ago = now_utc - timedelta(days=7)
        res = await session.execute(
            select(func.count(User.id)).where(
                User.subscription_expiry >= _7d_ago,
                User.subscription_expiry <= now_utc,
            )
        )
        stats["churned_7d"] = res.scalar_one() or 0

        # Revenue 7d sparkline
        _7d_start = (now_utc - timedelta(days=6)).replace(hour=0, minute=0, second=0, microsecond=0)
        day_col = func.date_trunc("day", Transaction.created_at)
        res = await session.execute(
            select(
                day_col.label("day"),
                func.sum(
                    sa_case(
                        (Transaction.currency == "XTR", Transaction.amount * 1.2),
                        (Transaction.currency.in_(["USDT", "USD"]), Transaction.amount * 95),
                        else_=Transaction.amount,
                    )
                ).label("rev"),
            )
            .where(Transaction.status == "paid", Transaction.created_at >= _7d_start)
            .group_by(day_col)
            .order_by(day_col)
        )
        rev_by_day = {row.day.date(): round(float(row.rev or 0)) for row in res.all()}
        rev_7d_labels = []
        rev_7d_data = []
        for i in range(6, -1, -1):
            d = (now_utc - timedelta(days=i)).date()
            rev_7d_labels.append(d.strftime("%d.%m"))
            rev_7d_data.append(rev_by_day.get(d, 0))
        stats["rev_7d_labels"] = rev_7d_labels
        stats["rev_7d_data"] = rev_7d_data

        # Recent transactions
        from sqlalchemy import desc

        res = await session.execute(
            select(Transaction).order_by(desc(Transaction.created_at)).limit(10)
        )
        for tx in res.scalars():
            recent_transactions.append({
                "user_id": tx.user_id,
                "amount": float(tx.amount or 0),
                "currency": tx.currency or "RUB",
                "status": tx.status,
                "description": getattr(tx, "description", None),
                "plan": getattr(tx, "plan", None),
                "created_at_fmt": _fmt_msk(tx.created_at) if tx.created_at else "",
            })

    # Xray stats + expiring users + expiry calendar
    async def _fetch_system_stats():
        engine = get_engine()
        async with async_session() as sess:
            return await engine.get_system_stats(sess)

    xray_stats, expiring_users, expiry_calendar = await asyncio.gather(
        _fetch_system_stats(),
        _get_expiring_users(),
        _get_expiry_calendar(),
    )

    vpn = {}
    if xray_stats:
        vpn["vpn_users"] = xray_stats.get("total_user", 0)
        vpn["active_users"] = xray_stats.get("users_active", 0)
        bw_in = xray_stats.get("incoming_bandwidth", 0)
        bw_out = xray_stats.get("outgoing_bandwidth", 0)
        vpn["bw_in_gb"] = round(bw_in / 1024 / 1024 / 1024, 2)
        vpn["bw_out_gb"] = round(bw_out / 1024 / 1024 / 1024, 2)

    return {
        "stats": stats,
        "vpn": vpn,
        "recent_transactions": recent_transactions,
        "expiring_users": expiring_users,
        "expiry_calendar": expiry_calendar,
    }


async def _get_expiring_users() -> list[dict]:
    """Get VPN users expiring within 3 days."""
    try:
        now = datetime.now(timezone.utc)
        soon = now + timedelta(days=3)
        async with async_session() as session:
            result = await session.execute(
                select(User.vpn_username, User.subscription_expiry)
                .where(
                    User.is_active == True,
                    User.vpn_uuid.isnot(None),
                    User.subscription_expiry.isnot(None),
                    User.subscription_expiry > now,
                    User.subscription_expiry < soon,
                )
                .order_by(User.subscription_expiry)
                .limit(8)
            )
            rows = result.all()
        expiring = []
        for uname, exp_dt in rows:
            if exp_dt:
                exp_msk = exp_dt.replace(tzinfo=timezone.utc).astimezone(_MSK)
                expiring.append({
                    "username": uname,
                    "expire_fmt": exp_msk.strftime("%d.%m %H:%M"),
                })
        return expiring
    except Exception:
        return []


async def _get_expiry_calendar() -> list[dict]:
    """Get all active subscriptions grouped by expiry date (sorted nearest->furthest)."""
    try:
        now = datetime.now(timezone.utc)
        async with async_session() as session:
            day_col = func.date_trunc("day", User.subscription_expiry)
            result = await session.execute(
                select(day_col.label("d"), func.count(User.id))
                .where(
                    User.is_active == True,
                    User.vpn_uuid.isnot(None),
                    User.subscription_expiry.isnot(None),
                    User.subscription_expiry > now,
                )
                .group_by(day_col)
                .order_by(day_col)
            )
            rows = result.all()
        calendar = []
        for dt, cnt in rows:
            if dt:
                dt_msk = dt.replace(tzinfo=timezone.utc).astimezone(_MSK)
                calendar.append({
                    "date": dt_msk.strftime("%d.%m.%y"),
                    "count": cnt,
                })
        return calendar
    except Exception:
        logger.exception("Failed to get expiry calendar")
        return []


@router.get("/stats/funnel", response_model=FunnelResponse)
async def api_funnel(days: int = 30, _=Depends(require_auth)):
    """Get conversion funnel data."""
    data = await _get_funnel_data(days)
    return data


@cached("funnel:{days}", ttl=60)
async def _get_funnel_data(days: int) -> dict:
    """Fetch funnel data (cached 60s)."""
    now = datetime.now(timezone.utc)
    start_date = now - timedelta(days=days)

    _stage_types = [
        "bot_start", "view_plans", "trial_click", "trial_activated",
        "select_plan", "payment_initiated", "payment_success",
    ]
    _stage_labels = {
        "bot_start": "Старт бота",
        "view_plans": "Просмотр тарифов",
        "trial_click": "Клик на триал",
        "trial_activated": "Триал активирован",
        "select_plan": "Выбор тарифа",
        "payment_initiated": "Начал оплату",
        "payment_success": "Оплатил",
    }

    async with async_session() as session:
        # Stages -- single GROUP BY query
        q = await session.execute(
            select(
                AnalyticsEvent.event_type,
                func.count(distinct(AnalyticsEvent.user_id)),
            )
            .where(
                AnalyticsEvent.event_type.in_(_stage_types),
                AnalyticsEvent.timestamp >= start_date,
            )
            .group_by(AnalyticsEvent.event_type)
        )
        stage_counts = {row[0]: row[1] for row in q.all()}

        total_starts = stage_counts.get("bot_start", 0)
        stages = []
        for st in _stage_types:
            count = stage_counts.get(st, 0)
            rate = round(count / total_starts * 100, 1) if total_starts > 0 else 0
            stages.append({
                "name": st,
                "label": _stage_labels.get(st, st),
                "count": count,
                "rate": rate,
            })

        # Daily chart -- single GROUP BY
        day_col = func.date_trunc("day", AnalyticsEvent.timestamp)
        q = await session.execute(
            select(
                day_col.label("day"),
                AnalyticsEvent.event_type,
                func.count(distinct(AnalyticsEvent.user_id)),
            )
            .where(
                AnalyticsEvent.event_type.in_(["bot_start", "payment_success"]),
                AnalyticsEvent.timestamp >= start_date,
            )
            .group_by(day_col, AnalyticsEvent.event_type)
            .order_by(day_col)
        )
        daily_map = {}
        for row in q.all():
            day_str = row[0].strftime("%d.%m")
            if day_str not in daily_map:
                daily_map[day_str] = {"date": day_str, "starts": 0, "payments": 0}
            if row[1] == "bot_start":
                daily_map[day_str]["starts"] = row[2]
            elif row[1] == "payment_success":
                daily_map[day_str]["payments"] = row[2]

    total_payments = stage_counts.get("payment_success", 0)

    return {
        "days": days,
        "stages": stages,
        "daily_chart": list(daily_map.values()),
        "total_starts": total_starts,
        "total_payments": total_payments,
        "overall_conversion": round(total_payments / total_starts * 100, 1) if total_starts > 0 else 0,
    }
