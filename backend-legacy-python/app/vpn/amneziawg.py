"""AmneziaWG management via wg-easy REST API.

This is a SEPARATE SERVICE from the xray protocol plugin system.
AmneziaWG uses wg-easy REST API (WireGuard-based), completely independent
from xray inbounds/outbounds. It should NOT be registered as a Protocol plugin.
"""

import aiohttp
import asyncio
import logging
import json
from typing import Any, Optional

from app.config import get_settings

logger = logging.getLogger(__name__)

_instance: Optional["AmneziaWGService"] = None


class AmneziaWGService:
    """Manages AmneziaWG peers across multiple wg-easy servers."""

    def __new__(cls):
        global _instance
        if _instance is None:
            _instance = super().__new__(cls)
            _instance._initialized = False
        return _instance

    def __init__(self):
        if self._initialized:
            return
        self._initialized = True
        settings = get_settings()
        self.servers = settings.awg_servers
        self.password = settings.awg_password
        self.timeout = aiohttp.ClientTimeout(total=15)
        # Session cookies per server (host -> cookie_jar)
        self._cookies: dict[str, aiohttp.CookieJar] = {}

    async def _login(self, server: dict) -> aiohttp.CookieJar:
        """Login to wg-easy API and return cookie jar."""
        host = server["host"]
        port = server["api_port"]
        jar = aiohttp.CookieJar(unsafe=True)  # Required for IP-based hosts

        async with aiohttp.ClientSession(cookie_jar=jar, timeout=self.timeout) as session:
            async with session.post(
                f"http://{host}:{port}/api/session",
                json={"password": self.password},
            ) as resp:
                if resp.status == 200:
                    self._cookies[host] = jar
                    return jar
                else:
                    text = await resp.text()
                    logger.error("AWG login failed on %s: %s %s", host, resp.status, text)
                    raise ConnectionError(f"AWG login failed on {host}: {resp.status}")

    async def _get_session(self, server: dict) -> aiohttp.CookieJar:
        """Get or create authenticated session for server."""
        host = server["host"]
        if host not in self._cookies:
            return await self._login(server)
        return self._cookies[host]

    async def _api_call(self, server: dict, method: str, path: str,
                        json_data: dict = None, retry: bool = True) -> Optional[Any]:
        """Make authenticated API call to wg-easy."""
        host = server["host"]
        port = server["api_port"]
        jar = await self._get_session(server)

        try:
            async with aiohttp.ClientSession(cookie_jar=jar, timeout=self.timeout) as session:
                url = f"http://{host}:{port}{path}"
                kwargs = {"json": json_data} if json_data else {}

                async with session.request(method, url, **kwargs) as resp:
                    if resp.status == 401 and retry:
                        # Re-login and retry
                        del self._cookies[host]
                        return await self._api_call(server, method, path, json_data, retry=False)

                    if resp.status in (200, 201):
                        content_type = resp.headers.get("Content-Type", "")
                        if "application/json" in content_type:
                            return await resp.json()
                        text = await resp.text()
                        return text if text else True

                    if resp.status == 204:
                        return True  # No Content = success (delete/enable/disable)

                    text = await resp.text()
                    logger.error("AWG API error %s %s on %s: %s %s",
                                 method, path, host, resp.status, text)
                    return None

        except asyncio.TimeoutError:
            logger.error("AWG API timeout: %s %s on %s", method, path, host)
            return None
        except Exception as e:
            logger.error("AWG API exception: %s %s on %s: %s", method, path, host, e)
            return None

    async def list_clients(self, server: dict) -> list:
        """List all AWG clients on a server."""
        result = await self._api_call(server, "GET", "/api/wireguard/client")
        return result if isinstance(result, list) else []

    async def find_client_by_name(self, server: dict, name: str) -> Optional[dict]:
        """Find AWG client by name on a server."""
        clients = await self.list_clients(server)
        for client in clients:
            if client.get("name") == name:
                return client
        return None

    async def create_client(self, server: dict, name: str) -> Optional[dict]:
        """Create AWG client. Returns client info or None."""
        result = await self._api_call(
            server, "POST", "/api/wireguard/client",
            json_data={"name": name},
        )
        # wg-easy API may return various formats on success (dict, empty, etc.)
        # Always try to find the client after POST succeeds (result is not None)
        if result is not None:
            return await self.find_client_by_name(server, name)
        return None

    async def get_client_config(self, server: dict, client_id: str) -> Optional[str]:
        """Get WireGuard config text for a client."""
        return await self._api_call(
            server, "GET", f"/api/wireguard/client/{client_id}/configuration",
        )

    async def enable_client(self, server: dict, client_id: str) -> bool:
        """Enable AWG client."""
        result = await self._api_call(
            server, "POST", f"/api/wireguard/client/{client_id}/enable",
        )
        return result is not None

    async def disable_client(self, server: dict, client_id: str) -> bool:
        """Disable AWG client."""
        result = await self._api_call(
            server, "POST", f"/api/wireguard/client/{client_id}/disable",
        )
        return result is not None

    async def delete_client(self, server: dict, client_id: str) -> bool:
        """Delete AWG client."""
        result = await self._api_call(
            server, "DELETE", f"/api/wireguard/client/{client_id}",
        )
        return result is not None

    async def create_user_on_all_servers(self, username: str) -> dict:
        """Create AWG peer on all servers. Returns {server_name: client_id}."""
        peers = {}

        async def _create_on(srv):
            name = srv["name"]
            # Check if already exists
            existing = await self.find_client_by_name(srv, username)
            if existing:
                peers[name] = existing["id"]
                logger.info("AWG peer %s already exists on %s", username, name)
                return

            client = await self.create_client(srv, username)
            if client:
                peers[name] = client["id"]
                logger.info("AWG peer %s created on %s: %s", username, name, client["id"])
            else:
                logger.error("Failed to create AWG peer %s on %s", username, name)

        await asyncio.gather(*[_create_on(s) for s in self.servers])
        return peers

    async def get_user_configs(self, username: str) -> dict:
        """Get AWG configs for user from all servers. Returns {server_name: config_text}."""
        configs = {}

        async def _get_from(srv):
            name = srv["name"]
            client = await self.find_client_by_name(srv, username)
            if not client:
                return
            cfg = await self.get_client_config(srv, client["id"])
            if cfg:
                configs[name] = cfg

        await asyncio.gather(*[_get_from(s) for s in self.servers])
        return configs

    async def enable_user_on_all_servers(self, username: str) -> None:
        """Enable AWG peer on all servers."""
        async def _enable_on(srv):
            client = await self.find_client_by_name(srv, username)
            if client:
                await self.enable_client(srv, client["id"])

        await asyncio.gather(*[_enable_on(s) for s in self.servers])

    async def disable_user_on_all_servers(self, username: str) -> None:
        """Disable AWG peer on all servers."""
        async def _disable_on(srv):
            client = await self.find_client_by_name(srv, username)
            if client:
                await self.disable_client(srv, client["id"])

        await asyncio.gather(*[_disable_on(s) for s in self.servers])
