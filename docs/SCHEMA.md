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
| `state.yaml` | What's deployed right now in prod | backend marker + nodes, iOS build + ASC id, fork + repo state, App Store state, known-issues |
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

Single document. The current operational truth — update with EVERY
production change (deploy / TestFlight upload / fork rebuild).

```yaml
last-updated: 2026-05-14           # ISO date
last-updated-by: claude            # owner of the latest edit
prod:
  backend:
    version-marker: 60.5-…         # configBuildMarker — tracks clientconfig.go
                                   # revisions only; a comment below it lists
                                   # code shipped since the marker
    nodes:                         # list of {id, host, provider, role}
      - { id: de, host: 1.2.3.4, provider: OVH, role: primary vpn node + api }
    deployed: 2026-05-14
    env-flags: { CHAMELEON_DISABLE_QUIC_OUTBOUNDS: "true" }   # optional
  ios:
    marketing-version: "1.0.26"
    current-build: 71              # last UPLOADED build
    track: testflight-internal
    asc-build-id: <uuid>
    uploaded: 2026-05-14
    field-verified: false          # bool; flip after on-device confirm
    previous-builds-in-testflight: [70, 69, …]
    libbox: { source: …, binary-size-mb: 44, git-ignored: true }
    # pending-build: optional sub-map while a build is mid-pipeline
  fork:
    repo: github.com/…
    branch: v1.13.5-madfrog
    base-tag: v1.13.5
    cherry-picks: [feat(group/urltest)/firstwrite-callback]
    pushed-to-origin: true
    remote-branch: origin/v1.13.5-madfrog
  chameleon-repo:
    branch: claude/…
    pushed-to-origin: true
    head: <short-sha>              # one commit stale right after a commit — expected
    unpushed-commits: 0
  app-store:
    version: "1.0.26"
    state: WAITING_FOR_REVIEW      # mirrors ASC appStoreState
    submission-id: <uuid>          # the reviewSubmission id
    attached-build: 71
    submitted: 2026-05-14

known-issues:
  - id: throttle-cycle-90s         # stable id
    severity: major                # blocker | major | minor | cosmetic
    description: |
      <what's wrong>
    status-update: MITIGATED 2026-05-14 — <what changed>   # optional, dated
    next-action: phase-1-smart-group | none
```

## Schema: `plan.yaml`

```yaml
phases:
  - id: phase-1.c-adaptive-cadence  # PERMALINK — never rename
    title: Adaptive probe cadence on cellular
    status: done                    # see status enum below
    completed: 2026-05-13           # ISO date, when status=done|reverted
    builds: [61, 62]                # related TestFlight build numbers
    layer: ios                      # ios | backend | fork | infra | docs
    rationale: |
      <why we're doing this; field-log evidence>
    # ─ optional, as the phase warrants: ─
    artifacts: [<file paths this phase touched>]
    implementation: |               # prose: how it was built
    tests: |                        # prose: what test coverage shipped with it
    shipped: |                      # prose: ship details (build/asc-id/notes)
    notes: |                        # caveats; required for reverted/deferred/abandoned
    related-incidents: [<incidents.yaml ids>]
    related-decisions: [<decisions.yaml ADR ids>]
    depends-on: <phase id>
    blocked-on: |                   # prose, while status=in-progress
    follow-up: [<phase ids that depend on this>]
    estimated-effort: <free text>
    outcome:                        # when done, if there's a metric
      metric: fallback-latency-ms
      value: 9
      previous: 21000
```

Allowed statuses:
- `planned`: scheduled, no work started
- `in-progress`: actively being implemented (`blocked-on:` if stuck)
- `done`: shipped + (optionally) field-verified
- `reverted`: the phase's *artifact* shipped and was then rolled back —
  keep the entry for history. NOT for "the decision was wrong but the
  artifact stayed" — that's `done` with a `notes:` caveat.
- `deferred`: paused — reasons in `notes:`
- `abandoned`: decided not to do — reasons in `notes:`

Order in the file is roughly grouped (smart-selection rollout → launch
readiness → fork track), NOT strictly chronological. Never rely on file
position — filter by `status` / `id` / `layer`. Append new phases to the
end of their group; never reorder existing entries.

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

## Topology — not a `docs/` file

Server / relay / chain topology is **canonical at
`infrastructure/topology.yaml`** and is deliberately NOT mirrored into
`docs/architecture/`. If a doc needs to reference topology, link the
`infrastructure/` path directly. (`components.yaml` has an `infra-topology`
entry that does exactly this.)

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
