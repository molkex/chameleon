-- VPN servers table — replaces VPN_SERVERS env variable.
-- Stores server list in DB for live management without container restart.

CREATE TABLE IF NOT EXISTS vpn_servers (
    id          SERIAL PRIMARY KEY,
    key         VARCHAR(64)  NOT NULL UNIQUE,
    name        VARCHAR(128) NOT NULL,
    flag        VARCHAR(16)  NOT NULL DEFAULT '',
    host        VARCHAR(128) NOT NULL,
    port        INTEGER      NOT NULL DEFAULT 2096,
    domain      VARCHAR(256) NOT NULL DEFAULT '',
    sni         VARCHAR(256) NOT NULL DEFAULT '',
    is_active   BOOLEAN      NOT NULL DEFAULT true,
    sort_order  INTEGER      NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Seed current servers
INSERT INTO vpn_servers (key, name, flag, host, port, sni, sort_order) VALUES
    ('relay-de', 'Russia → DE',    '🇷🇺', '185.218.0.43',  443,  '',          0),
    ('relay-nl', 'Russia → NL',    '🇷🇺', '185.218.0.43',  2098, 'rutube.ru', 1),
    ('de',       'Germany',         '🇩🇪', '162.19.242.30', 2096, '',          2),
    ('nl',       'Netherlands',     '🇳🇱', '194.135.38.90', 2096, 'rutube.ru', 3)
ON CONFLICT (key) DO NOTHING;
