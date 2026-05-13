# Pre-YAML migration archive (2026-05-13)

These files were the canonical docs before the YAML-first reorg.
Migrated content lives in the new files at `docs/`. Keep these for
historical reference (e.g. how a phase was originally framed); do not
edit them.

## Where each file's content went

| Archived file | New home(s) |
|---|---|
| `ROADMAP.md` | Phases → `plan.yaml`. Current state → `state.yaml`. Launch checklist still here, will migrate when launch work resumes. |
| `SMART_SELECTION_PLAN.md` | Phases → `plan.yaml`. Incident retros → `incidents.yaml`. Architecture choices → `decisions.yaml`. Long-form anti-patterns + references list still here. |
| `TROUBLESHOOTING.md` | Each issue → `incidents.yaml`. Initial pass covers 2026-04-24 OVH ASN block + 2026-05-13 OOM + DPI filter + build 61 polish. Older incidents not migrated; will backfill on demand. |
| `TARGET_ARCHITECTURE.md` | Component shape → `architecture/components.yaml`. Strategic targets → `plan.yaml` (later horizon). |
| `architecture.yaml` | Replaced by `architecture/components.yaml` (different shape, see SCHEMA.md). Old yaml superseded. |
| `roadmap.yaml` | Replaced by `plan.yaml`. |
| `troubleshooting.yaml` | Replaced by `incidents.yaml`. |
| `release-notes/` | Each note → entry in `builds.yaml`. Only 1.0.24 builds 31-35 had notes; builds 36-54 gap not yet backfilled, builds 55-62 fully captured. |

## Why the move

See `docs/decisions.yaml` § `ADR-002-yaml-first-docs` for the full
rationale. Short version: knowledge drifted across mirrored MD/YAML
files; this consolidates to YAML-as-truth with one human navigator
(`docs/INDEX.md`).
