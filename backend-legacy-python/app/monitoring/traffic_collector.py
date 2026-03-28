"""
Background traffic collector — reads xray gRPC stats every 30 minutes,
saves TrafficSnapshot records for analytics, and accumulates
User.cumulative_traffic so totals persist across xray restarts.
"""

import asyncio
import logging
from datetime import datetime, timezone

from sqlalchemy import select, func

from app.config import get_settings
from app.database.db import async_session
from app.database.models import TrafficSnapshot, User

logger = logging.getLogger(__name__)

COLLECT_INTERVAL_SECONDS = 30 * 60  # 30 minutes


async def _get_last_snapshots(session) -> dict[str, int]:
    """Get the most recent used_traffic per user from TrafficSnapshot.

    Returns {vpn_username: last_used_traffic_bytes}.
    """
    # Subquery: max timestamp per user
    sub = (
        select(
            TrafficSnapshot.vpn_username,
            func.max(TrafficSnapshot.timestamp).label("max_ts"),
        )
        .group_by(TrafficSnapshot.vpn_username)
        .subquery()
    )
    rows = (
        await session.execute(
            select(TrafficSnapshot.vpn_username, TrafficSnapshot.used_traffic)
            .join(
                sub,
                (TrafficSnapshot.vpn_username == sub.c.vpn_username)
                & (TrafficSnapshot.timestamp == sub.c.max_ts),
            )
        )
    ).all()
    return {r[0]: r[1] for r in rows}


async def collect_once():
    """Run a single collection cycle using ChameleonEngine traffic stats."""
    from app.vpn import stats as vpn_stats

    # Refresh traffic from xray gRPC stats API
    stats = await vpn_stats.get_all_stats()
    if not stats:
        # Fallback to module-level cache
        stats = vpn_stats._traffic_cache
        if stats:
            logger.info("Using cached traffic data (%d users)", len(stats))

    if not stats:
        logger.warning("No traffic data available (gRPC query and cache both empty)")
        return 0

    now = datetime.now(timezone.utc).replace(tzinfo=None)

    async with async_session() as session:
        # Get last snapshot per user for delta calculation
        last_snapshots = await _get_last_snapshots(session)

        # Build username → User mapping for cumulative update
        uname_list = list(stats.keys())
        user_rows = (
            await session.execute(
                select(User).where(User.vpn_username.in_(uname_list))
            )
        ).scalars().all()
        user_map = {u.vpn_username: u for u in user_rows}

        snapshots = []
        updated_users = 0
        for username, traffic in stats.items():
            up = traffic.get("up", 0) or 0
            down = traffic.get("down", 0) or 0
            current_total = up + down

            snapshots.append(TrafficSnapshot(
                vpn_username=username,
                used_traffic=current_total,
                download_traffic=down,
                upload_traffic=up,
                timestamp=now,
            ))

            # Compute delta and accumulate into User.cumulative_traffic
            prev_total = last_snapshots.get(username, 0) or 0
            if current_total >= prev_total:
                # Normal growth
                delta = current_total - prev_total
            else:
                # Xray restarted — counter reset to 0, current_total is new traffic
                delta = current_total
                if prev_total > 0:
                    logger.info(
                        "Xray restart detected for %s: prev=%d, cur=%d, delta=%d",
                        username, prev_total, current_total, delta,
                    )

            if delta > 0:
                user = user_map.get(username)
                if user:
                    user.cumulative_traffic = (user.cumulative_traffic or 0) + delta
                    updated_users += 1

        session.add_all(snapshots)
        await session.commit()

    logger.info(
        "Collected traffic: %d snapshots, %d users updated (cumulative)",
        len(snapshots), updated_users,
    )
    return len(snapshots)


async def traffic_collector_loop():
    """Infinite loop — collect every COLLECT_INTERVAL_SECONDS."""
    logger.info("Traffic collector started (interval=%ds)", COLLECT_INTERVAL_SECONDS)

    # Wait a bit for xray to become available
    await asyncio.sleep(30)

    while True:
        try:
            await collect_once()
        except Exception as e:
            logger.exception("Traffic collector error: %s", e)
        await asyncio.sleep(COLLECT_INTERVAL_SECONDS)
