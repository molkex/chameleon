---
title: YAML for state, Markdown for narrative — one source of truth per topic
date: 2026-05-28
status: active
tags: [docs, conventions]
---

# 0006 — YAML state, Markdown narrative

## Context

The `docs/` folder had grown to 13+ files with a **`.md` + `.yaml` mirror pattern** for 6 of them (architecture, operations, payments, troubleshooting, roadmap). The intent was "humans read .md, agents read .yaml". The reality was:

- Edits required updating both files. Half the time only one got updated → drift.
- The mirror banner ("🤖 keep in sync") was advice, not enforcement.
- For long-form narrative (post-mortems, "why we chose X"), YAML is unreadable.
- For structured live facts (server IPs, ASC IDs, IAP states), Markdown is fine for humans but a pain for any script trying to parse them out.

Memory (`~/.claude/projects/.../memory/`) also grew to 48 files with no convention — same drift risk.

## Decision

**Pick the format per topic, not per audience.**

- **YAML** in `docs/state/` for things that are **facts about the current world**: server IPs, ASC IDs, IAP states, DNS records, runtime processes. Agents grep, scripts parse, humans skim.
- **Markdown** for **narrative**: decisions (`docs/decisions/`), playbooks (`docs/playbooks/`), incidents (`docs/incidents/`), architecture (`docs/arch/`).
- **`roadmap.yaml`** is the one exception — roadmap is structured enough (now/next/later/done) that YAML wins.
- **Delete** the existing `.md` + `.yaml` mirrors. Keep `.md` (where the narrative lives), drop `.yaml` (mirror).

Full convention in [`../README.md`](../README.md).

## Migration approach

**Incremental**, not big-bang.

This ADR creates the folder structure (`state/`, `arch/`, `decisions/`, `playbooks/`, `incidents/`) and migrates a minimal first set:

- ROADMAP.md → `roadmap.yaml` (full).
- ARCHITECTURE_MESH.md → `arch/mesh.md` (rename only).
- TARGET_ARCHITECTURE.md → `arch/target.md` (rename only).
- First 5 ADRs (this one + 0001..0005).
- First 3 playbooks (apple reject recovery, ios CLI release, deploy NL).
- 4 state YAMLs (servers, app-store, runtime, domains).
- 2 incidents (MED-015 restart loop, Apple 2.3 reject).

**Not migrated yet** (touch as work goes through them):

- `OPERATIONS.md` (1555 lines) — split into playbooks over time.
- `TROUBLESHOOTING.md` — only top 2 entries pulled to `incidents/`; rest stays until touched.
- `PAYMENTS.md` — will become `arch/payments.md` + state when revisited.

## Consequences

- New work goes in the new structure from day one.
- Legacy files stay accessible (no link rot) until incrementally migrated.
- `docs/README.md` is authoritative on "where things live".
- `.claude/CLAUDE.md` updated with the same rules so every new Claude session knows.

## Status

Active. Re-evaluate after a month of usage — does it actually reduce drift? Does anyone find anything? If not, simplify further.
