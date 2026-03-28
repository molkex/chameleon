"""Direct xray API client — async wrapper around xray CLI commands.

Uses asyncio.create_subprocess_exec for non-blocking docker exec calls.
Replaces slow per-stat queries with batch operations.
"""

import asyncio
import json
import logging
import os

logger = logging.getLogger(__name__)

# Inbound tags → email suffix and flow
INBOUND_DEFS: list[dict] = [
    {"tag": "VLESS TCP REALITY", "suffix": "xray", "flow": "xtls-rprx-vision"},
    {"tag": "VLESS XHTTP REALITY", "suffix": "xhttp", "flow": ""},
    {"tag": "VLESS gRPC REALITY", "suffix": "grpc", "flow": ""},
    {"tag": "VLESS WS CDN", "suffix": "ws", "flow": ""},
]

EMAIL_SUFFIXES = [d["suffix"] for d in INBOUND_DEFS]


class XrayAPI:
    """Async xray API client via docker exec CLI."""

    def __init__(self, container: str | None = None, api_port: int | None = None):
        self.container = container or os.environ.get("XRAY_CONTAINER", "xray")
        self.api_port = api_port or int(os.environ.get("XRAY_STATS_PORT", "10085"))
        self._server = f"127.0.0.1:{self.api_port}"
        self._docker_available: bool | None = None  # Lazy-checked on first use

    # ── User Management ──

    async def add_user(self, inbound_tag: str, uuid: str, email: str, flow: str = "") -> bool:
        """Add a single user to an inbound via `xray api adi`."""
        user_obj: dict = {"id": uuid, "email": email}
        if flow:
            user_obj["flow"] = flow
        rc, _, stderr = await self._exec_xray(
            "api", "adi", f"--server={self._server}", inbound_tag, json.dumps(user_obj),
        )
        if rc != 0:
            logger.warning("add_user failed [%s] %s: %s", inbound_tag, email, stderr[:200])
        return rc == 0

    async def remove_user(self, inbound_tag: str, email: str) -> bool:
        """Remove a user from an inbound via `xray api rmu`."""
        rc, _, stderr = await self._exec_xray(
            "api", "rmu", f"--server={self._server}", inbound_tag, email,
        )
        if rc != 0:
            logger.debug("remove_user failed [%s] %s: %s", inbound_tag, email, stderr[:200])
        return rc == 0

    async def add_user_to_all_inbounds(self, uuid: str, username: str, short_id: str = "") -> bool:
        """Add user to all known inbounds (TCP, XHTTP, gRPC, WS) concurrently."""
        tasks = [
            self.add_user(d["tag"], uuid, f"{username}@{d['suffix']}", d["flow"])
            for d in INBOUND_DEFS
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        ok = sum(1 for r in results if r is True)
        if ok < len(INBOUND_DEFS):
            logger.warning("add_user_to_all: %s added to %d/%d inbounds", username, ok, len(INBOUND_DEFS))
        return ok > 0

    async def remove_user_from_all_inbounds(self, username: str) -> bool:
        """Remove user from all inbounds concurrently."""
        tasks = [
            self.remove_user(d["tag"], f"{username}@{d['suffix']}")
            for d in INBOUND_DEFS
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        ok = sum(1 for r in results if r is True)
        return ok > 0

    # ── Stats ──

    async def query_user_traffic(self, username: str, reset: bool = False) -> dict[str, int]:
        """Query traffic for a user across all inbounds. Returns {up, down}."""
        up = down = 0
        for suffix in EMAIL_SUFFIXES:
            email = f"{username}@{suffix}"
            for direction in ("uplink", "downlink"):
                pattern = f"user>>>{email}>>>traffic>>>{direction}"
                val = await self._query_single_stat(pattern, reset=reset)
                if direction == "uplink":
                    up += val
                else:
                    down += val
        return {"up": up, "down": down}

    async def query_all_traffic(self) -> dict[str, dict[str, int]]:
        """Batch query all user traffic via single statsquery call."""
        rc, stdout, _ = await self._exec_xray(
            "api", "statsquery", f"--server={self._server}", "-pattern=user>>>",
            timeout=10.0,
        )
        result: dict[str, dict[str, int]] = {}
        if rc != 0 or not stdout:
            return result

        current_name = ""
        for line in stdout.splitlines():
            line = line.strip()
            if line.startswith("name:"):
                current_name = line.split('"')[1] if '"' in line else ""
            elif line.startswith("value:") and current_name:
                val = int(line.split(":", 1)[1].strip())
                parts = current_name.split(">>>")
                if len(parts) == 4:
                    uname = parts[1].split("@")[0]
                    if uname not in result:
                        result[uname] = {"up": 0, "down": 0}
                    key = "up" if parts[3] == "uplink" else "down"
                    result[uname][key] += val
                current_name = ""
        return result

    async def get_sys_stats(self) -> dict:
        """Get xray system stats (goroutines, memory, etc.)."""
        rc, stdout, _ = await self._exec_xray(
            "api", "statssys", f"--server={self._server}",
        )
        if rc != 0 or not stdout:
            return {}
        stats: dict = {}
        for line in stdout.splitlines():
            line = line.strip()
            if ":" in line:
                k, v = line.split(":", 1)
                k, v = k.strip(), v.strip()
                try:
                    stats[k] = int(v)
                except ValueError:
                    stats[k] = v
        return stats

    # ── Health ──

    async def health_check(self) -> bool:
        """Verify xray is running and gRPC API responds."""
        if not await self.is_running():
            return False
        # Quick gRPC probe — statssys always works if API is up
        rc, _, _ = await self._exec_xray(
            "api", "statssys", f"--server={self._server}", timeout=3.0,
        )
        return rc == 0

    async def is_running(self) -> bool:
        """Check if xray container is running."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "inspect", "-f", "{{.State.Running}}", self.container,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5.0)
            return proc.returncode == 0 and b"true" in stdout
        except Exception:
            return False

    async def reload(self) -> bool:
        """Reload xray config via SIGHUP."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "kill", "--signal=SIGHUP", self.container,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(proc.communicate(), timeout=5.0)
            return proc.returncode == 0
        except Exception as e:
            logger.error("reload failed: %s", e)
            return False

    async def restart(self) -> bool:
        """Restart xray container."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "restart", self.container,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(proc.communicate(), timeout=30.0)
            return proc.returncode == 0
        except Exception as e:
            logger.error("restart failed: %s", e)
            return False

    # ── Docker validation ──

    async def _check_docker(self) -> bool:
        """Verify Docker CLI is available. Result is cached for the lifetime of this instance."""
        if self._docker_available is not None:
            return self._docker_available
        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "version",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(proc.communicate(), timeout=5.0)
            self._docker_available = proc.returncode == 0
        except FileNotFoundError:
            self._docker_available = False
        except Exception:
            self._docker_available = False

        if not self._docker_available:
            logger.warning("Docker CLI not available — xray API calls will be no-ops")
        return self._docker_available

    # ── Internal ──

    async def _exec_xray(self, *args: str, timeout: float = 5.0) -> tuple[int, str, str]:
        """Run `docker exec <container> xray <args>`, return (rc, stdout, stderr)."""
        if not await self._check_docker():
            return -1, "", "docker not available"
        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "exec", self.container, "xray", *args,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            stdout_b, stderr_b = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            return proc.returncode or 0, stdout_b.decode(), stderr_b.decode()
        except asyncio.TimeoutError:
            logger.warning("xray command timed out: %s", " ".join(args[:3]))
            return -1, "", "timeout"
        except FileNotFoundError:
            logger.debug("Docker CLI not available")
            return -1, "", "docker not found"
        except Exception as e:
            logger.debug("xray exec error: %s", e)
            return -1, "", str(e)

    async def _query_single_stat(self, pattern: str, reset: bool = False) -> int:
        """Query a single stat value."""
        cmd = ["api", "statsquery", f"--server={self._server}", f"-pattern={pattern}"]
        if reset:
            cmd.append("-reset")
        rc, stdout, _ = await self._exec_xray(*cmd)
        if rc == 0 and stdout:
            for line in stdout.splitlines():
                line = line.strip()
                if line.startswith("value:"):
                    return int(line.split(":", 1)[1].strip())
        return 0
