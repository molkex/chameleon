"""REST API v1: Node management endpoints."""

import logging

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from app.dependencies import get_engine
from app.database.db import async_session
from app.monitoring.node_metrics import get_all_nodes_metrics, collect_node_metrics, NODES
from app.auth.rbac import require_auth

logger = logging.getLogger(__name__)

router = APIRouter()


def _find_node(key: str) -> dict | None:
    """Find a node config by key."""
    for node in NODES:
        if node["key"] == key:
            return node
    return None


@router.get("/nodes")
async def api_list_nodes(_=Depends(require_auth)):
    """List all nodes with their current status and metrics."""
    try:
        nodes = await get_all_nodes_metrics()
        # Enrich with cost data from NODES config
        cost_map = {n["key"]: n for n in NODES}
        total_cost = 0
        for node in nodes:
            cfg = cost_map.get(node["key"], {})
            node["provider"] = cfg.get("provider")
            node["cost_monthly_rub"] = cfg.get("cost_monthly_rub", 0)
            total_cost += node["cost_monthly_rub"]
        return {"nodes": nodes, "total_cost_monthly_rub": total_cost}
    except Exception as e:
        logger.exception("API: list nodes failed: %s", e)
        return JSONResponse({"error": "Internal server error"}, status_code=500)


@router.post("/nodes/{key}/check")
async def api_check_node(key: str, _=Depends(require_auth)):
    """Run health check on a specific node."""
    node = _find_node(key)
    if not node:
        return JSONResponse({"error": "unknown node"}, status_code=404)

    try:
        metrics = await collect_node_metrics(node)
        return JSONResponse({"ok": True, "node": key, "metrics": metrics})
    except Exception as e:
        logger.exception("API: check node %s failed: %s", key, e)
        return JSONResponse({"ok": False, "error": "Internal server error"}, status_code=500)


@router.post("/nodes/sync")
async def api_sync_nodes(_=Depends(require_auth)):
    """Sync Xray config to all remote nodes."""
    try:
        engine = get_engine()
        async with async_session() as session:
            await engine._sync_nodes(session)
        logger.info("API: synced nodes config")
        return JSONResponse({"ok": True})
    except Exception as e:
        logger.exception("API: sync nodes failed: %s", e)
        return JSONResponse({"ok": False, "error": "Internal server error"}, status_code=500)
