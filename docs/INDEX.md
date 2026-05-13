# Chameleon VPN — Documentation index

> Start here. This is the single human navigator. Canonical facts live
> in the YAML files; this page tells you which file to open.

## 🟢 What's running right now

→ [`state.yaml`](state.yaml) — backend version on prod, iOS build in
TestFlight, fork branch state, known-issues list.

## 🎯 What we plan / are doing / have done

→ [`plan.yaml`](plan.yaml) — phases (`planned` / `in-progress` / `done` /
`reverted` / `deferred` / `abandoned`). Each phase has rationale,
artifacts, outcome metrics, and links to related incidents.

Quick filter examples (run from repo root):
```sh
yq '.phases[] | select(.status=="planned") | {id,title,layer}' docs/plan.yaml
yq '.phases[] | select(.status=="done") | .id' docs/plan.yaml
yq '.phases[] | select(.layer=="ios" and .status=="done") | .title' docs/plan.yaml
```

## 🚨 What broke + why

→ [`incidents.yaml`](incidents.yaml) — field-failures and post-mortems.
Use these to avoid re-debugging the same misdirections. Each incident
includes initial hypothesis (right or wrong), root cause, the phase
that fixed it, and lessons.

## 💭 Why we built it this way

→ [`decisions.yaml`](decisions.yaml) — ADR-style architecture decisions
with context, consequences, alternatives rejected.

## 📦 Per-build release log

→ [`builds.yaml`](builds.yaml) — every TestFlight upload with ASC build
id, included phases, field-verification status, evidence pointer.

## 📐 Architecture

→ [`architecture/`](architecture/) — high-level component map.
- `components.yaml` — modules + their contracts.
- `mesh.md` — diagrams.
- **Topology** lives at `infrastructure/topology.yaml` (canonical, not
  duplicated here).

## 🛠 Operations + payments

These are vertical-specific docs not migrated to the YAML schema:
- [`OPERATIONS.md`](OPERATIONS.md) — deploy procedures, runbooks.
- [`PAYMENTS.md`](PAYMENTS.md) — business vertical.
- [`PLAN-auto-renewing-migration.md`](PLAN-auto-renewing-migration.md) — frozen plan, historical.

## 📚 Archive

→ [`archive/`](archive/) — superseded docs preserved for history.
Old `ROADMAP.md`, `SMART_SELECTION_PLAN.md`, `TROUBLESHOOTING.md` are
here. Read `archive/2026-05-pre-yaml/README.md` for the migration map.

---

## Editing rules (short version)

- Add to YAML, not MD. Each entry needs a stable `id`.
- See [`SCHEMA.md`](SCHEMA.md) for the contract per file.
- Never delete an entry — set status to `reverted` / `abandoned` /
  `deprecated`. Git history is preserved either way; explicit status
  carries the *reason*.

## Common queries

```sh
# What's the most recent incident?
yq '.incidents | sort_by(.date) | .[-1]' docs/incidents.yaml

# Which phases ship in build 62?
yq '.builds[] | select(.number==62) | .phases' docs/builds.yaml

# All decisions about the fork?
yq '.decisions[] | select(.title | test("fork"; "i"))' docs/decisions.yaml
```
