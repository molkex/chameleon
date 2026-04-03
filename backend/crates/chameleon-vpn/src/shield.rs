//! ChameleonShield — server-controlled protocol priorities (Redis-backed).
//!
//! The shield endpoint is implemented in `chameleon-apple::mobile::shield`.
//! It reads the `shield:config` key from Redis for dynamic overrides,
//! falling back to hardcoded defaults derived from enabled protocols.
//!
//! Admin can set `shield:config` in Redis as a JSON string to override
//! protocol priorities without restarting the server.
