"""Shared test fixtures for Chameleon VPN backend."""

import os

import pytest

# Override env vars BEFORE importing app code so Settings() picks them up
os.environ.update({
    "DATABASE_URL": "postgresql+asyncpg://test:test@localhost/test",
    "REDIS_URL": "redis://localhost:6379/1",
    "REALITY_PRIVATE_KEY": "test_private_key_placeholder",
    "REALITY_PUBLIC_KEY": "test_public_key_placeholder",
    "REALITY_SNIS": "ads.x5.ru,eh.vk.com",
    "ADMIN_USERNAME": "admin",
    "ADMIN_PASSWORD": "test_password_123",
    "HY2_PASSWORD": "",
    "HY2_OBFS_PASSWORD": "",
    "WARP_PRIVATE_KEY": "",
    "ANYTLS_PASSWORD": "",
})

from app.config import Settings  # noqa: E402
from app.vpn.protocols.base import ServerConfig, UserCredentials  # noqa: E402


@pytest.fixture
def settings():
    return Settings(
        database_url="postgresql+asyncpg://test:test@localhost/test",
        redis_url="redis://localhost:6379/1",
        reality_private_key="test_private_key_placeholder",
        reality_public_key="test_public_key_placeholder",
        reality_snis=["ads.x5.ru", "eh.vk.com"],
        admin_username="admin",
        admin_password="test_password_123",
    )


@pytest.fixture
def test_user():
    return UserCredentials(
        username="user_1",
        uuid="550e8400-e29b-41d4-a716-446655440000",
        short_id="abcd1234",
    )


@pytest.fixture
def test_servers():
    return [
        ServerConfig(
            host="1.2.3.4",
            port=2096,
            domain="nl1.example.com",
            flag="\U0001f1f3\U0001f1f1",
            name="Netherlands",
            key="nl",
        ),
        ServerConfig(
            host="5.6.7.8",
            port=2096,
            domain="de1.example.com",
            flag="\U0001f1e9\U0001f1ea",
            name="Germany",
            key="de",
        ),
    ]
