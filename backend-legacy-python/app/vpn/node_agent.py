"""Chameleon Node Agent — runs on each VPN node alongside xray.

Consumes Redis Stream events and manages local xray via gRPC.
Reports heartbeat metrics back to Redis for monitoring.

Usage:
    python -m app.vpn.node_agent --node-key nl-01 --group-id 1 --redis-url redis://master:6379/0
    python -m app.vpn.node_agent --node-key de-01 --group-id 2 --api-url http://master:8000
"""

import argparse
import asyncio
import json
import logging
import os
import time

import httpx
import redis.asyncio as aioredis

from app.vpn.xray_api import XrayAPI

logger = logging.getLogger(__name__)

HEARTBEAT_INTERVAL = 30  # seconds
STREAM_BLOCK_MS = 5000   # block on XREADGROUP for 5s


class NodeAgent:
    """Consumes Redis Stream events and manages local xray."""

    def __init__(self, node_key: str, group_id: int, redis_url: str, api_url: str = "", api_key: str = ""):
        self.node_key = node_key
        self.group_id = group_id
        self.redis_url = redis_url
        self.api_url = api_url.rstrip("/")
        self.api_key = api_key
        self.stream_key = f"stream:node_group:{group_id}"
        self.consumer_group = f"node_agents:{group_id}"
        self.xray = XrayAPI()
        self._redis: aioredis.Redis | None = None
        self._running = False

    async def run(self) -> None:
        """Main loop: consume events, report heartbeat."""
        self._redis = aioredis.from_url(self.redis_url, decode_responses=False)
        self._running = True

        # Create consumer group (ignore if exists)
        try:
            await self._redis.xgroup_create(self.stream_key, self.consumer_group, id="0", mkstream=True)
        except aioredis.ResponseError as e:
            if "BUSYGROUP" not in str(e):
                raise

        logger.info("Node agent %s started (group=%d, stream=%s)", self.node_key, self.group_id, self.stream_key)

        # Also consume global stream (group 0)
        global_stream = "stream:node_group:0"
        global_group = "node_agents:0"
        try:
            await self._redis.xgroup_create(global_stream, global_group, id="0", mkstream=True)
        except aioredis.ResponseError as e:
            if "BUSYGROUP" not in str(e):
                raise

        last_heartbeat = 0.0
        while self._running:
            try:
                # Read from both group-specific and global streams
                streams = {
                    self.stream_key: ">",
                    global_stream: ">",
                }
                results = await self._redis.xreadgroup(
                    self.consumer_group if self.stream_key == global_stream else self.consumer_group,
                    self.node_key,
                    streams,
                    count=10,
                    block=STREAM_BLOCK_MS,
                )

                for stream_name, messages in (results or []):
                    for msg_id, data in messages:
                        event_type = data.get(b"type", b"").decode()
                        payload_raw = data.get(b"payload", b"{}").decode()
                        payload = json.loads(payload_raw)

                        await self._process_event(event_type, payload)

                        # ACK the message
                        group = global_group if stream_name == global_stream.encode() else self.consumer_group
                        await self._redis.xack(stream_name, group, msg_id)

                # Periodic heartbeat
                now = time.monotonic()
                if now - last_heartbeat >= HEARTBEAT_INTERVAL:
                    await self._heartbeat()
                    last_heartbeat = now

            except aioredis.ConnectionError:
                logger.warning("Redis connection lost, reconnecting in 5s...")
                await asyncio.sleep(5)
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error("Event loop error: %s", e)
                await asyncio.sleep(1)

        if self._redis:
            await self._redis.aclose()

    async def _process_event(self, event_type: str, payload: dict) -> None:
        """Handle user_add, user_remove, full_sync."""
        logger.info("Processing event: %s", event_type)

        if event_type == "user_add":
            username = payload["username"]
            uuid = payload["uuid"]
            short_id = payload.get("short_id", "")
            ok = await self.xray.add_user_to_all_inbounds(uuid=uuid, username=username, short_id=short_id)
            if ok:
                logger.info("Added user %s via gRPC", username)
            else:
                logger.warning("gRPC add failed for %s, requesting full_sync", username)
                await self._full_sync()

        elif event_type == "user_remove":
            username = payload["username"]
            ok = await self.xray.remove_user_from_all_inbounds(username)
            if ok:
                logger.info("Removed user %s via gRPC", username)
            else:
                logger.warning("gRPC remove failed for %s", username)

        elif event_type == "full_sync":
            await self._full_sync()

        else:
            logger.debug("Unknown event type: %s", event_type)

    async def _full_sync(self) -> None:
        """Download full config from master API and restart xray."""
        if not self.api_url or not self.api_key:
            logger.warning("Cannot full_sync: api_url or api_key not configured")
            return

        try:
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.get(
                    f"{self.api_url}/api/v1/node/config",
                    headers={"X-Node-Key": self.api_key},
                )
                resp.raise_for_status()
                data = resp.json()

            config = data["config"]
            config_json = json.dumps(config, indent=2, ensure_ascii=False)

            config_path = os.environ.get("XRAY_CONFIG_PATH", "/etc/xray/config.json")
            os.makedirs(os.path.dirname(config_path), exist_ok=True)
            with open(config_path, "w") as f:
                f.write(config_json)

            # Reload xray
            proc = await asyncio.create_subprocess_exec(
                "docker", "kill", "--signal=SIGHUP", self.xray.container,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
            logger.info("Full sync complete (version=%s)", data.get("version", "?"))

        except Exception as e:
            logger.error("Full sync failed: %s", e)

    async def _heartbeat(self) -> None:
        """Report node status and metrics to Redis."""
        if not self._redis:
            return
        try:
            health_ok = await self.xray.health_check()
            await self._redis.hset(f"node_heartbeat:{self.node_key}", mapping={
                "status": "up" if health_ok else "degraded",
                "ts": str(int(time.time())),
                "group_id": str(self.group_id),
            })
            await self._redis.expire(f"node_heartbeat:{self.node_key}", HEARTBEAT_INTERVAL * 3)
        except Exception as e:
            logger.debug("Heartbeat failed: %s", e)

    def stop(self) -> None:
        self._running = False


def main() -> None:
    parser = argparse.ArgumentParser(description="Chameleon Node Agent")
    parser.add_argument("--node-key", required=True, help="Unique node identifier (e.g. nl-01)")
    parser.add_argument("--group-id", type=int, default=0, help="Node group ID")
    parser.add_argument("--redis-url", default=os.environ.get("REDIS_URL", "redis://localhost:6379/0"))
    parser.add_argument("--api-url", default=os.environ.get("MASTER_API_URL", ""))
    parser.add_argument("--api-key", default=os.environ.get("NODE_API_KEY", ""))
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    agent = NodeAgent(
        node_key=args.node_key, group_id=args.group_id,
        redis_url=args.redis_url, api_url=args.api_url, api_key=args.api_key,
    )
    asyncio.run(agent.run())


if __name__ == "__main__":
    main()
