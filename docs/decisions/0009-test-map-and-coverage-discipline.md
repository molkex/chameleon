# 0009 — test-map.yaml + coverage discipline

- Status: accepted
- Date: 2026-06-01
- Supersedes: none (extends 0006-yaml-state-md-narrative)

## Context

We had no single place answering "what is covered by tests, how do I verify each
layer, and where are the gaps?" Coverage knowledge lived in people's heads and in
scattered `*_test.go` / `Tests/*.swift` files. A 2026-06-01 audit found real,
security-relevant gaps (Apple IAP JWS verification, admin-login credential path,
live VPN provisioning, the entire admin SPA) that nothing tracked. New work kept
shipping without a forcing function to either add a test or record the gap.

## Decision

1. **`docs/state/test-map.yaml` is the single source of truth for test coverage.**
   One entry per backend package / apple module / admin / infra service: what it
   does, which test file covers it, status (tested/partial/untested), coverage %,
   and the known gaps. It carries a top-level `verify:` block listing the canonical
   command to check each layer — that block IS the definition of "how we verify".

2. **Gaps are tracked, not forgotten.** Every untested critical path gets a `TEST-*`
   id in `test-map.yaml#gaps_by_priority` AND a mirrored item in
   `roadmap.yaml#next.testing`. Priority by blast radius: money → auth →
   live-provisioning → everything else.

3. **The discipline (forcing function):** every code change either ships with a test
   OR adds/updates the relevant `TEST-*` gap. Every change that adds/removes a test
   updates `test-map.yaml`. This is appended to `AGENTS.md` so every agent honors it.

4. **YAML, not MD** — coverage is *current state*, so it follows 0006: agents parse
   it cheaply, it refreshes in place (not append-only like decisions/incidents).

## Why this shape

- A coverage map as code/CI output (e.g. raw `go test -cover`) can't express the
  *apple* side (tests can't run locally — app-group host crash) or the *admin* side
  (no framework yet) or *infra* (`sing-box check`). A curated YAML can describe all
  four layers uniformly and stays honest about what "verified" means per layer.
- Keeping the verify-commands beside the coverage means one read tells an agent both
  the state and how to re-check it — no second lookup.

## Consequences

- `test-map.yaml` must be refreshed when packages/tests change, or it rots like any
  snapshot. The `meta.updated` + `verified_via` fields make staleness visible.
- The first population (2026-06-01) recorded the backlog as TEST-APPLE-IAP,
  TEST-AUTH-CREDS, TEST-IOS-SUBMGR, TEST-ADMIN-SPA, TEST-FREEKASSA, TEST-VPN-ENGINE,
  TEST-IOS-CI, TEST-GEOIP. Closing them is now ordinary roadmap work.
