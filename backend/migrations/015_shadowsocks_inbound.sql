-- Add Shadowsocks (chacha20-ietf-poly1305) inbound support to VPN servers.
-- NULL means the protocol is not available on that server.
--
-- Motivation: home routers (Keenetic + kvas, OpenWrt, etc.) ship with
-- shadowsocks-libev natively but cannot run VLESS Reality / Hysteria2 / TUIC.
-- A per-node Shadowsocks inbound lets those routers tunnel through the same
-- nodes without changing the rest of the protocol stack.
--
-- Password is a server-wide secret (classic SS does not support multi-user
-- on chacha20-ietf-poly1305 in sing-box; that's only in 2022-blake3-* methods).
-- For SS-2022 / per-user keys, schema would need a separate users table.
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS shadowsocks_port INTEGER DEFAULT NULL;
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS shadowsocks_password TEXT DEFAULT NULL;
