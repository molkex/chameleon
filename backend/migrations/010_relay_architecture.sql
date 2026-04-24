-- Relay/exit architecture: RU-based relay entry nodes that chain via
-- WireGuard to foreign exit nodes. Enables LTE users to reach
-- ASN-blocked exits (e.g. OVH) by entering through a RU-whitelisted
-- relay first.
--
-- See memory/project_relay_architecture_poc.md for design history
-- and docs/ROADMAP.md "Launch analysis" section.

-- Role in topology. 'exit' = foreign egress node (existing behaviour).
-- 'relay' = RU entry that forwards to exits via WG.
ALTER TABLE vpn_servers
    ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'exit'
    CHECK (role IN ('exit', 'relay'));

-- ISO-3166-1 alpha-2. For exits = egress country. For relays = relay location.
ALTER TABLE vpn_servers
    ADD COLUMN IF NOT EXISTS country_code CHAR(2);

-- User API base URL for pushing users to remote sing-box-fork instances.
-- Populated only for role='relay' nodes (chameleon backend doesn't run there,
-- so the backend running on an exit node reaches the relay's User API over
-- the public internet, UFW-restricted). Exit nodes leave this NULL — the
-- backend running co-located talks to 127.0.0.1 directly via engine config.
-- Secrets are NOT stored in DB (see CHAMELEON_RELAY_SECRETS env var).
ALTER TABLE vpn_servers
    ADD COLUMN IF NOT EXISTS user_api_url TEXT;

-- Junction: a WireGuard tunnel from one relay to one exit.
-- The relay's sing-box has an inbound tagged `relay_inbound_tag` listening
-- on `relay_listen_port`; route rules in the relay config send all traffic
-- from that inbound through this WG tunnel to the exit, which egresses.
-- Client VLESS URL for this chain = (relay.host:relay_listen_port).
CREATE TABLE IF NOT EXISTS relay_exit_peers (
    id                     BIGSERIAL PRIMARY KEY,
    relay_server_key       TEXT NOT NULL REFERENCES vpn_servers(key) ON DELETE CASCADE,
    exit_server_key        TEXT NOT NULL REFERENCES vpn_servers(key) ON DELETE CASCADE,

    -- TCP port on the relay where VLESS inbound accepts clients for this
    -- exit direction.
    relay_listen_port      INTEGER NOT NULL,

    -- sing-box inbound tag on the relay (e.g. 'vless-de', 'vless-nl').
    -- RelayUserSyncer uses this to target the correct User API endpoint
    -- when pushing users: PUT /api/v1/inbounds/<tag>/users.
    relay_inbound_tag      TEXT NOT NULL,

    -- WireGuard tunnel between relay (peer) and exit (server).
    wg_exit_endpoint_port  INTEGER NOT NULL DEFAULT 51820,
    wg_exit_pub            TEXT NOT NULL,      -- exit's WG server pubkey
    wg_relay_peer_priv     TEXT NOT NULL,      -- relay's WG privkey (inside sing-box)
    wg_relay_peer_pub      TEXT NOT NULL,      -- relay's WG pubkey (goes into exit [Peer])
    wg_subnet_cidr         TEXT NOT NULL,      -- e.g. 10.66.66.0/24
    wg_relay_address       TEXT NOT NULL,      -- e.g. 10.66.66.2/32

    is_active              BOOLEAN NOT NULL DEFAULT true,
    created_at             TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    UNIQUE (relay_server_key, exit_server_key)
);

CREATE INDEX IF NOT EXISTS idx_relay_exit_peers_relay
    ON relay_exit_peers (relay_server_key) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_relay_exit_peers_exit
    ON relay_exit_peers (exit_server_key)  WHERE is_active;

-- Backfill country_code for existing exits.
UPDATE vpn_servers SET country_code = 'DE' WHERE key = 'de'            AND country_code IS NULL;
UPDATE vpn_servers SET country_code = 'NL' WHERE key IN ('nl', 'nl2')  AND country_code IS NULL;

-- Seed MSK relay row. Reality private key left empty — the relay already
-- holds keys on disk (/etc/sing-box/reality.keys) and runs independently;
-- backend only needs the PUBLIC key to render in client configs.
-- is_active=false: migration is safe to apply before RelayUserSyncer has
-- a chance to push users. Flip to true via admin/psql after verifying sync.
INSERT INTO vpn_servers
    (key, name, flag, host, port, domain, sni,
     reality_public_key, reality_private_key,
     is_active, sort_order,
     provider_name, cost_monthly, provider_url, provider_login, provider_password, notes,
     role, country_code, user_api_url)
SELECT 'msk', 'MSK Relay (Timeweb)', '🇷🇺', '217.198.5.52', 0, '', 'music.yandex.ru',
       'OJSR6FJytgohcFEUU4YD_IBdc3X83SUuez0n5tskTUs',
       '',
       false, 100,
       'Timeweb Cloud', 350.0, 'https://timeweb.cloud', '', '',
       'RU-whitelist entry relay. Chains via WG to DE/NL exits. Flip is_active=true after RelayUserSyncer verified.',
       'relay', 'RU',
       'http://217.198.5.52:15380'
WHERE NOT EXISTS (SELECT 1 FROM vpn_servers WHERE key = 'msk');

-- Seed PoC relay-exit peers. is_active=false initially — flip to true after
-- RelayUserSyncer populates MSK inbounds successfully and an iPhone client
-- config renders and connects through the chain.
INSERT INTO relay_exit_peers
    (relay_server_key, exit_server_key, relay_listen_port, relay_inbound_tag,
     wg_exit_endpoint_port, wg_exit_pub, wg_relay_peer_priv, wg_relay_peer_pub,
     wg_subnet_cidr, wg_relay_address, is_active)
SELECT 'msk', 'de', 2096, 'vless-de',
       51820,
       '9h36gtdE0heVGYmFurR/5TrUuM7o2niCMFqm5LRgumc=',
       'SGeZ8hk+BNBiDcDIfmJryHh8rKLUBRS0iDgmfI/UFkY=',
       'VJpa1yqcoXbGKMG/zbJOTwHCPIMqKwWUdQO51Ft9LkI=',
       '10.66.66.0/24', '10.66.66.2/32', false
WHERE EXISTS (SELECT 1 FROM vpn_servers WHERE key = 'de')
  AND NOT EXISTS (SELECT 1 FROM relay_exit_peers WHERE relay_server_key = 'msk' AND exit_server_key = 'de');

INSERT INTO relay_exit_peers
    (relay_server_key, exit_server_key, relay_listen_port, relay_inbound_tag,
     wg_exit_endpoint_port, wg_exit_pub, wg_relay_peer_priv, wg_relay_peer_pub,
     wg_subnet_cidr, wg_relay_address, is_active)
SELECT 'msk', 'nl2', 2097, 'vless-nl',
       51820,
       'V1zydC3JOpDR/OV9eHBn7GtA9yW0vcLSEmQqgfmYImI=',
       'UJ5HPj2PbAnBhBteb7iARfil7GOMLe5htF/fikF5hUI=',
       'wye/o7Cn0Pu2/ePPFf0K8SbKzSpjRyMgb+hCl7fGHHk=',
       '10.77.77.0/24', '10.77.77.2/32', false
WHERE EXISTS (SELECT 1 FROM vpn_servers WHERE key = 'nl2')
  AND NOT EXISTS (SELECT 1 FROM relay_exit_peers WHERE relay_server_key = 'msk' AND exit_server_key = 'nl2');
