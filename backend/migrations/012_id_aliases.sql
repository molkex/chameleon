-- Migration 012: id_aliases table for cross-node user_id mapping.
--
-- Background: users-table has a local autoincrement `id`. With cluster sync
-- (Redis Pub/Sub + HTTP reconcile in internal/cluster) the same logical user
-- (matched by vpn_uuid) ends up with DIFFERENT `id` values on each node.
-- Because mobile JWTs encode `id` from whichever node minted them, a token
-- issued on NL routes to a non-existent id on DE → 404 on /config.
--
-- Fix: backend FindUserByID, after a direct miss, consults id_aliases.
-- Migrating off federated multi-master to single-source-of-truth (DE) — all
-- former NL ids are populated here as alt_id pointing to their canonical
-- DE id. iOS clients with stale JWTs in Keychain transparently keep working.
--
-- alt_id is the legacy/foreign id that historically appeared in JWTs;
-- real_id is the canonical users.id row that owns the data.
--
-- Idempotent: CREATE ... IF NOT EXISTS guards re-application via deploy.sh.

CREATE TABLE IF NOT EXISTS id_aliases (
    alt_id     INTEGER PRIMARY KEY,
    real_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source     VARCHAR(32) NOT NULL,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS id_aliases_real_id_idx ON id_aliases(real_id);
