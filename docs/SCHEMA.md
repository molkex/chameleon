# Documentation schema — YAML-first project knowledge base

> **Read this first** before editing any YAML in `docs/`. The schema is the
> contract that keeps multiple agents (humans, Claude, future tooling)
> writing the same shape of data. Drift here breaks `yq` queries and the
> auto-generated INDEX.

## Why YAML, not Markdown

- **Compact**: ~30-40% fewer tokens than equivalent prose. Material when an
  agent loads the whole knowledge base into context.
- **Machine-readable**: `yq '.phases[] | select(.status=="done")'` returns
  a structured result in one shell call. Markdown requires parsing or LLM.
- **Atomic entries**: each phase / incident / decision is one mapping. No
  "where in the markdown do I add this" — append a new mapping at the end
  of the list.
- **Lifecycle visible**: `status:` field replaces ✅/⏳/❌ glyph soup. Filters
  by status are trivial.

Markdown is reserved for:
- `INDEX.md` — single human entry point (navigation only).
- `architecture/mesh.md` — diagrams that don't compress to YAML.
- `archive/` — preserved historical writeups.

## Files

| File | Purpose | One-line summary |
|---|---|---|
| `state.yaml` | What's deployed right now in prod | "DE+NL at backend 60.3, iOS build 62 in Internal Testers" |
| `plan.yaml` | Phases — what we will / are / have done | Living lifecycle of every named change |
| `incidents.yaml` | What broke + root cause + lesson | Field-failures and post-mortems |
| `decisions.yaml` | ADR — architectural choices | "Why fork sing-box", "Why no Cloudflare Tunnel" |
| `builds.yaml` | Per-build release log | Every TestFlight upload with ASC id + content |
| `test-coverage.yaml` | What's tested / what's a gap | Coverage map + prioritized gap list |
| `architecture/components.yaml` | iOS / backend / fork modules | High-level component map |

Vertical-specific docs (not migrated to this schema):
- `OPERATIONS.md` — deploy procedures, runbooks. Process docs, not facts.
- `PAYMENTS.md` — separate business vertical.
- `PLAN-auto-renewing-migration.md` — frozen migration plan, kept as
  historical reference until removed.

## Common field conventions

Every entry across all files MUST include:

- `id`: stable identifier. Format: `<topic>-<short-name>` for phases,
  `<YYYY-MM-DD>-<short-name>` for incidents, `ADR-NNN-<short-name>` for
  decisions. Don't change after creation — other files reference it.
- One date field: `date`, `created`, `completed`, depending on entity.
  Always ISO `YYYY-MM-DD`.

Status enums (use exactly these strings, lowercase, hyphenated):

- `plan.yaml` phases: `planned` | `in-progress` | `done` | `reverted` |
  `deferred` | `abandoned`
- `incidents.yaml` severity: `blocker` | `major` | `minor` | `cosmetic`
- `decisions.yaml`: `proposed` | `accepted` | `superseded` | `deprecated`
- `builds.yaml` track: `testflight-internal` | `testflight-public` |
  `app-store` | `archived`

## Schema: `state.yaml`

Single document. The current operational truth.

```yaml
last-updated: 2026-05-13          # ISO date
last-updated-by: claude            # owner of the latest edit
prod:
  backend:
    version: 60.3-dpi-aware-config # configBuildMarker
    nodes: [de, nl]
    deployed: 2026-05-13
  ios:
    version: 1.0.26
    build: 62
    track: testflight-internal
    field-verified: false          # bool; flip after user confirms
  fork:
    branch: v1.13.5-madfrog
    base: sing-box v1.13.5
    head: <sha>
    pushed: false                  # bool; true after origin push

known-issues:
  - issue: throttle-cycle-90s
    severity: major
    description: nl-via-msk throttles at ~90s of bulk flow, fallback re-elects same
    next-action: phase-1.d-penalty-score
```

## Schema: `plan.yaml`

```yaml
phases:
  - id: phase-1.c-adaptive-cadence
    title: Adaptive probe cadence on cellular
    status: done                   # see status enum above
    created: 2026-05-13
    completed: 2026-05-13          # only when status=done|reverted
    builds: [61, 62]               # related TestFlight build numbers
    layer: ios                     # ios | backend | fork | infra | docs
    rationale: |
      <why we're doing this; field-log evidence>
    artifacts:                     # files this phase touched
      - clients/apple/PacketTunnel/TunnelStallProbe.swift
    related-incidents: []          # ids from incidents.yaml
    related-decisions: []          # ids from decisions.yaml
    follow-up:                     # phase ids that depend on this
      - phase-1.d-penalty-score
    outcome:                       # only when done
      metric: fallback-latency-ms
      value: 9
      previous: 21000
```

Allowed statuses:
- `planned`: scheduled, no work started
- `in-progress`: actively being implemented
- `done`: shipped + (optionally) field-verified
- `reverted`: shipped but rolled back — keep entry for history
- `deferred`: paused — reasons in `notes:`
- `abandoned`: decided not to do — reasons in `notes:`

## Schema: `incidents.yaml`

```yaml
incidents:
  - id: 2026-05-13-libbox-1.13.6-oom
    date: 2026-05-13
    severity: blocker              # blocker | major | minor | cosmetic
    title: libbox v1.13.6 OOM-killer storm on iOS NE
    builds-affected: [56, 57, 58]
    detected-via: field-log        # field-log | user-report | telemetry | review
    symptoms:
      - sing-box internal oom-killer fires ~500x/sec
      - memory pressure: critical at 43 MiB
    initial-hypothesis: |
      v1.13.5→v1.13.6 sing-box base regression. Reverted to v1.13.5.
    initial-hypothesis-outcome: wrong
    root-cause: |
      Config inflation. 44 outbounds × ~1 MiB each on Go heap,
      QUIC leaves dead but reserved BBR state.
    fixed-by:
      - phase-1.a-quic-suppress    # phase id from plan.yaml
    lessons:
      - Don't roll back base version without isolating root cause
      - Profile heap before blaming version drift
```

## Schema: `decisions.yaml`

Architecture Decision Records. Add when a choice has non-obvious tradeoffs.

```yaml
decisions:
  - id: ADR-001-fork-singbox
    date: 2026-04-23
    status: accepted               # proposed | accepted | superseded | deprecated
    title: Maintain a permanent sing-box fork
    context: |
      Upstream sing-box rejected smart-outbound issue #2061 as "not planned".
      We need first-write callback, smart group, BBR telemetry.
    decision: |
      Maintain v1.13.5-madfrog branch with periodic upstream rebases.
    consequences:
      - Cherry-pick mihomo patches as needed
      - Pay rebase cost on each upstream release
    superseded-by: null            # ADR id when replaced
```

## Schema: `builds.yaml`

```yaml
builds:
  - number: 62
    version: 1.0.26
    date: 2026-05-13
    track: testflight-internal
    asc-build-id: 06ecd6af-cee8-41b4-b4d4-3a8afea37cb2
    phases:                        # ids from plan.yaml
      - phase-1.c-polish-log
    archive-path: /tmp/MadFrogVPN-build62.xcarchive
    field-verified: false
    notes: |
      Log quality refactor of Phase 1.C — single apply(_:) method, dedup
      log on no-op, profile transition format "X → Y", probe recovered event.
```

## Schema: `test-coverage.yaml`

Single document. The coverage map — which source modules have tests,
which are gaps, and the priority order to close them. Update whenever a
test file is added/removed OR an untested component ships.

```yaml
last-updated: 2026-05-14
last-updated-by: claude
summary:
  ios: { source-files: 65, test-files: 19, test-cases: ~189 }
  backend: { source-files: 69, test-files: 22, test-cases: ~110 }
ios:                               # same shape for `backend:`
  tested:                          # "Source.swift -> TestFile (N)"
    - WidgetVPNSnapshot.swift -> WidgetVPNSnapshotTests (5)
  behaviour-tests: []              # tests not mapped 1:1 to a file
  gaps:
    - id: ios-app-state            # stable id, referenceable
      path: clients/apple/MadFrogVPN/Models/AppState.swift
      severity: critical           # critical | major | minor | exempt
      why: |
        <why this matters / blast radius>
      what-to-test: |
        <concrete list of behaviours a test should pin>
  exempt:                          # explicitly not worth a unit test
    reason: <why>
    files: [<glob or path>, ...]
```

Gap severity:
- `critical` — load-bearing logic on the connect/pay/security path,
  shipped to prod, zero tests.
- `major` — real branching logic, untested, not on the hot path.
- `minor` — small/pure helper, low blast radius.
- `exempt` — UI view / thin OS-wrapper / generated / entrypoint.

## Schema: `architecture/components.yaml`

```yaml
components:
  - id: backend-config-generator
    layer: backend
    path: backend/internal/vpn/clientconfig.go
    responsibility: |
      Generates sing-box client config JSON for iOS/macOS from server/chain
      DB rows + ClientConfigOpts (geo hint, country-code filtering).
    consumes: [postgres.vpn_servers, geoip.Resolver]
    produces: [singbox-config-json]
    contracts:
      - configBuildMarker is a human-readable revision id (string)
      - emits no outbound without country_code
```

## Schema: `architecture/topology.yaml`

Already exists at `infrastructure/topology.yaml`. **Don't duplicate** —
`docs/architecture/topology.yaml` either re-exports the canonical file
via `$ref` or is a symlink. Decide once and stick to it.

## Cross-file references

When one entry references another, use the `id` string. Keep the namespace
distinct so a reader can tell what kind of reference it is:

- `phase-1.a-quic-suppress` → entry in `plan.yaml`
- `2026-05-13-libbox-1.13.6-oom` → entry in `incidents.yaml`
- `ADR-001-fork-singbox` → entry in `decisions.yaml`
- `build-62` → entry in `builds.yaml` (or just `62` in `phases.builds`)

A validator (TODO: `scripts/validate-docs.py`) can later check that every
`id` referenced from another file actually exists.

## Editing rules

1. **Never delete an entry** — set status to `reverted` / `abandoned` /
   `deprecated`. History is the point.
2. **`id` is immutable** — once committed, it's a permalink. Other entries
   reference it.
3. **Status is single-valued** — if a phase ships partially, split it into
   two phases. Don't invent `in-progress-but-mostly-done`.
4. **Evidence pointers**: when a phase or incident cites a field log,
   reference the log file path in the repo (or commit hash if it lives
   in chat). Future-you needs to find it without grep.
5. **YAML over Markdown for new content**. If markdown is the right tool
   (rare — diagrams, tutorials), put it in `architecture/` or a topic
   subfolder, and link it from `INDEX.md`.
