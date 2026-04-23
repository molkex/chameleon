-- Add Hysteria2 and TUIC v5 UDP protocol support to VPN servers.
-- NULL means the protocol is not available on that server.
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS hysteria2_port INTEGER DEFAULT NULL;
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS tuic_port INTEGER DEFAULT NULL;
