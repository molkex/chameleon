"""Node sync — Redis Stream events + SSH fallback.

Primary: publish 'full_sync' event to Redis Stream — node agents pick it up.
Fallback: SSH push for nodes without an agent installed.
"""

import json
import logging

import paramiko
from redis.asyncio import Redis

logger = logging.getLogger(__name__)


async def request_node_sync(redis: Redis, group_id: int | None = None) -> None:
    """Request nodes to sync config via Redis Stream event.

    Node agents consume stream:node_group:{group_id} and pull config via API.
    If group_id is None, publishes to the global stream (group 0).
    """
    stream_key = f"stream:node_group:{group_id or 0}"
    try:
        await redis.xadd(stream_key, {"type": "full_sync", "payload": json.dumps({})})
        logger.info("Published full_sync to %s", stream_key)
    except Exception as e:
        logger.error("Failed to publish full_sync: %s", e)


def ssh_sync_node(ip: str, password: str, config_json: str, name: str = "") -> None:
    """Legacy SSH push — fallback for nodes without agent. Blocking."""
    ssh_user = "ubuntu" if ip == "162.19.242.30" else "root"
    remote_path = "/root/chameleon/xray_config/config.json" if ssh_user == "ubuntu" else "/root/xray_config/config.json"
    sudo = "sudo " if ssh_user != "root" else ""

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(ip, username=ssh_user, password=password, timeout=10)
        if ssh_user != "root":
            tmp = f"/tmp/xray_config_{ip.replace('.', '_')}.json"
            sftp = client.open_sftp()
            with sftp.file(tmp, "w") as f:
                f.write(config_json)
            sftp.close()
            _, stdout, _ = client.exec_command(f"sudo cp {tmp} {remote_path} && rm {tmp}", timeout=10)
            stdout.read()
        else:
            sftp = client.open_sftp()
            with sftp.file(remote_path, "w") as f:
                f.write(config_json)
            sftp.close()
        _, stdout, _ = client.exec_command(f"{sudo}docker restart xray 2>/dev/null || true", timeout=30)
        stdout.read()
        logger.info("SSH sync %s (%s): done", name, ip)
    finally:
        client.close()
