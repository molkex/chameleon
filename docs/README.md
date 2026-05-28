# Chameleon VPN — Documentation

> **One source of truth per topic.** YAML for **state** (machine-parseable facts), Markdown for **narrative** (decisions, procedures, history).

This folder is the canonical knowledge base for the project. Everything in `~/.claude/projects/.../memory/` is Claude-private notes; everything humans + agents both read goes here.

## Where things live

| Folder              | Format | Purpose                                                                  | Editable?           |
|---------------------|--------|--------------------------------------------------------------------------|---------------------|
| `state/`            | YAML   | Current facts about the world: servers, ASC IDs, IAP states, domains     | Yes, anytime        |
| `arch/`             | MD     | System design — overview, current mesh, target architecture              | Yes, when shape changes |
| `decisions/`        | MD     | Architecture Decision Records (ADRs). Numbered, dated, immutable         | **Append-only** — supersede with new ADR |
| `playbooks/`        | MD     | How-to procedures: deploy, release, recover from incident                | Yes, refine over time |
| `incidents/`        | MD     | Post-mortems for production incidents. Dated, immutable                  | **Append-only**     |
| `release-notes/`    | MD     | Per-build user-facing release notes                                      | Append per release  |
| `roadmap.yaml`      | YAML   | Single roadmap: now / next / later / done / deferred                     | Yes, anytime        |

Reference docs that don't fit yet (will migrate as work touches them):

| File                                  | Status                                                                          |
|---------------------------------------|---------------------------------------------------------------------------------|
| `OPERATIONS.md`                       | Legacy — 1500+ lines. Split into `playbooks/` over time.                        |
| `TROUBLESHOOTING.md`                  | Legacy — incidents being migrated to `incidents/`. Don't add new entries here.  |
| `PAYMENTS.md`                         | Legacy — will become `arch/payments.md` + `state/payment-providers.yaml`.       |
| `archive/`                            | One-off snapshots (audits, retired plans). Keep for history.                    |

## Rules of the road

### Choosing the format

- **Is it a fact about current state that a script or agent would parse?** → YAML in `state/`.
- **Is it explaining WHY we chose something?** → ADR in `decisions/`.
- **Is it explaining HOW to do something?** → playbook in `playbooks/`.
- **Is it a record of what went wrong + how we fixed it?** → incident in `incidents/`.
- **Is it describing system shape?** → MD in `arch/`.

### Naming

- **Decisions:** `NNNN-kebab-case-title.md` (e.g. `0007-singbox-fork-user-api.md`). Number is sequential, never reused.
- **Incidents:** `YYYY-MM-DD-short-slug.md` (e.g. `2026-05-28-apple-2.3-reject.md`).
- **Playbooks:** `kebab-case-action.md` (e.g. `deploy-nl.md`, `apple-reject-recovery.md`).
- **State:** lowercase domain (e.g. `servers.yaml`, `app-store.yaml`).

### Front-matter

All Markdown files start with YAML front-matter:

```yaml
---
title: Short human title
date: 2026-05-28           # creation date
status: active|superseded|deprecated
tags: [vpn, apple, ios]
supersedes: 0003           # only for decisions that replace earlier ones (optional)
---
```

Front-matter is the only place to put metadata. The body is for content.

### One source of truth

If a topic appears in two files, **one of them is wrong** — even if they were synced yesterday. Pick the canonical one and link to it. The old `.md` + `.yaml` mirror pattern is **deprecated**: it forces double edits and always rots.

### Append-only folders

- `decisions/` — never edit an old ADR. If it's wrong, write a new one with `supersedes: NNNN` in front-matter.
- `incidents/` — never edit a published post-mortem. Add a follow-up if the situation changes.

### Linking

Use relative paths: `../arch/mesh.md`, `../state/servers.yaml`. Don't use absolute URLs to GitHub — they break on fork/rename.

## Migration progress

This convention was bootstrapped 2026-05-28. Migration is **incremental**, not big-bang:

- ✅ `state/`, `arch/`, `decisions/`, `playbooks/`, `incidents/` folders created
- ✅ ROADMAP.md → `roadmap.yaml` (single source)
- ✅ `.yaml` mirrors deleted (architecture, operations, payments, troubleshooting)
- 🟡 `OPERATIONS.md` (1500+ lines) still legacy — split as touched
- 🟡 `TROUBLESHOOTING.md` (legacy) — only top 2 incidents migrated; rest stays until touched
- 🟡 `PAYMENTS.md` still legacy

## Quick navigation

- **Current servers / IPs:** [`state/servers.yaml`](state/servers.yaml)
- **App Store IDs / IAP states:** [`state/app-store.yaml`](state/app-store.yaml)
- **What's running where:** [`state/runtime.yaml`](state/runtime.yaml)
- **Roadmap:** [`roadmap.yaml`](roadmap.yaml)
- **How to deploy NL:** [`playbooks/deploy-nl.md`](playbooks/deploy-nl.md)
- **How to release iOS via CLI:** [`playbooks/ios-cli-release.md`](playbooks/ios-cli-release.md)
- **Recovering from Apple reject:** [`playbooks/apple-reject-recovery.md`](playbooks/apple-reject-recovery.md)
- **All decisions:** [`decisions/`](decisions/)
- **All incidents:** [`incidents/`](incidents/)
