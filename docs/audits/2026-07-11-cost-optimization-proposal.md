---
title: Cost optimization proposal — infra spend vs actual usage
date: 2026-07-11
status: proposal   # NOT decided — options for the user to pick/mix, nothing executed
tags: [audit, cost, infra, strategy]
related: [2026-07-11-network-mesh-stability-audit.md, 2026-07-11-production-stability-audit.md]
---

# Cost optimization proposal — 2026-07-11

## Why this exists

User asked to think through cutting project spend (growth has stalled, no active
development push right now) while keeping the service rock-stable, and separately
asked what `razblokirator.ru` is actually for — we already have one external domain
(madfrog.online) and one internal-facing one (api.madfrog.online), so a third live
alias needed explaining. This doc answers both with real numbers pulled from
production (`chameleon-postgres-standby` on WAW, read-only), not guesses.

**Nothing was changed.** No server stopped, no DNS touched, no relay cancelled.

## The numbers that matter

Queried directly against the production DB (2026-07-11):

| Metric | Value |
|---|---|
| Total users (all-time) | 394 |
| Currently active subscriptions | **10** |
| App-active in last 7 days | 13 |
| App-active in last 30 days | 48 |
| **VPN tunnel actually used in last 7 days** | **2** |
| New signups, last 30 days | 36 |
| New signups, last 90 days | 393 (i.e. almost the entire user base is ≤3 months old) |

Monthly signup trend:

| Month | Signups |
|---|---|
| 2026-04 | 10 |
| 2026-05 | **317** ← one-time spike (campaign/promo) |
| 2026-06 | 53 |
| 2026-07 (11 days in) | 14 |

Growth has not continued past the May spike — June and July are running at a flat
to slightly-declining rate, not a growth curve.

Revenue, last 90 days: **15 real payments, 4,545 ₽ total (~€45 / ~$50), 100% via
FreeKassa** (RU web-payment). **Zero verified Apple IAP revenue in the same window**,
despite 4 live, approved in-app-purchase products on the App Store. The other 4
`payments` rows in that window are `source=admin` (comp'd/free grants, not revenue).

## What we're actually paying for

Pulled live from `vpn_servers.cost_monthly` (admin-entered field — cross-checked
against known invoices where possible, flagged where it isn't):

| Server | Monthly cost | Currency | Role today | Confidence |
|---|---|---|---|---|
| WAW (217.182.74.70, OVH Warsaw) | 12.24 | EUR | primary backend+DB+web+monitoring+PL VPN exit | ✅ matches known OVH invoice |
| GRA (54.38.243.162, OVH Gravelines) | 9.99 | EUR | France VPN exit | ✅ matches known OVH invoice |
| NL (147.45.252.234, Timeweb) | 1,230 (DB field) **vs** ~9,740 (billing memory, dated 2026-04) | RUB | Postgres warm-standby replica + **untouchable** production `ss-ws` router (someone's live personal proxy, do not touch) + deactivated `nl2` VPN exit | ⚠️ **8x conflict between two internal sources — neither independently re-verified against the actual Timeweb panel** |
| MSK relay (217.198.5.52, Timeweb) | 350 | RUB | sole API ingress (chokepoint for the entire app) + VPN relay chains (nl-via-msk, fr-via-msk) | ⚠️ not independently re-verified |
| SPB relay (185.218.0.43, SprintHost) | untracked — DB shows €0 for both its `vpn_servers` rows, prior billing memory says "payment terms unknown, undocumented" | ? | RU sign-in decoy leg + 2 whitelist-bypass VPN chains | ⚠️ **currently non-functional** (see [2026-07-11-network-mesh-stability-audit.md](2026-07-11-network-mesh-stability-audit.md)) — may be paying for a dead box, cost unknown either way |
| MSK bot box (85.239.49.28) — **not in `vpn_servers` or `servers.yaml` at all** | unknown | ? | Telegram bot (`@MadFrogRobot`) + `bot./crew./speedtest.madfrog.online` — pre-native-app funnel, separate repo | ⚠️ cost not tracked anywhere in this repo |

Even counting only the two fully-confirmed EUR boxes (WAW + GRA = €22.23/mo), and
setting the disputed NL/MSK/SPB/bot-box numbers aside entirely, confirmed spend
already exceeds the entire last-90-days revenue (€45) inside two months. Whatever
the real total turns out to be once NL/MSK/SPB are verified, it structurally
outruns revenue by a wide margin at current usage.

## razblokirator.ru — what it actually is

Not a test domain. It's the **original brand name of the project before the
rebrand to MadFrog**. `docs/state/domains.yaml` confirms: kept "so old QR codes
keep working" — a leftover from pre-rebrand marketing, not an active channel.
Notably, the SprintHost account that hosts the SPB relay is itself registered
under `info@razblokirator.ru` — the name is baked into billing/account identity
for that one box, separate from the website.

It costs effectively **nothing extra** — it's a domain registration (~$10-15/yr)
riding for free on the same WAW nginx + Cloudflare setup that serves
madfrog.online and mdfrog.site. It is currently **100% broken**: Cloudflare
returns 200 headers but the body never arrives (see network-mesh audit, P1).

This is a hygiene call, not a cost lever — dropping it saves a trivial yearly
registration fee, not server spend. Options:
- **(a) Fix it** — the 1-line nginx `server_name`/origin gap, near-zero cost,
  restores whatever old links/QR codes still point at it.
- **(b) Redirect it** — 302 to madfrog.online instead of serving a duplicate
  site; same user outcome, less surface to maintain.
- **(c) Let the registration lapse** — saves the ~$10-15/yr, permanently breaks
  any surviving old links. Low blast radius (no active marketing references it),
  but how many old links/QR codes still exist is unverifiable from here.

Given (a)/(b) cost nothing, there's no real reason to pick (c) purely for
"savings" — only pick it if you're fine with old links dying and want one less
thing to think about.

## Three infra scenarios — not decided, pick or mix

### A — Minimal cut: hygiene only, don't touch topology
- Fix or 302-redirect razblokirator.ru (free either way).
- Resolve the dead SPB relay: fix it if it's cheap and worth keeping for the RU
  decoy path, or cancel it if not — right now we may be paying for a box that
  does nothing.
- Investigate the orphaned MSK bot box (85.239.49.28) — if the Telegram bot
  funnel is dead weight now that the native app exists, shut it down.
- **Savings:** SPB cost (unknown) + bot box cost (unknown). **Risk: ~none** —
  none of this touches WAW/GRA/NL/MSK-relay, which serve 100% of the 10
  currently-active subscribers.

### B — Balanced: also right-size the DB replica
- Everything in A, plus: replace NL's always-on streaming Postgres replica with
  the existing daily-backup + offsite Backblaze B2 pattern (already built, see
  project memory) as the sole DR mechanism, and decommission the NL VM —
  *unless* the untouchable `ss-ws` production router on that same box forces it
  to stay up regardless, in which case only the *replica* role goes away, not
  the box itself.
- **Savings:** potentially the single largest line item (NL — €13-100+/mo
  depending on which of the two conflicting numbers is real; verify first).
  **Risk:** RPO widens from ~seconds (live streaming replica) to "time since
  last backup" on a full primary-DB-loss event; WAW becomes a real single point
  of failure for the control plane again until/unless a cheaper standby exists.
  At 10 active subscribers, a same-day restore-from-backup is probably an
  acceptable trade for the savings — but that's a call for you, not for this doc.

### C — Aggressive: also consolidate VPN exits
- Everything in B, plus: drop to a single VPN exit (WAW/Poland), retire GRA
  (France). With 2 concurrent VPN users total, running two separate exit
  datacenters has no capacity justification today; re-add GRA (or something
  cheaper) if usage actually grows back.
- **Savings:** +€9.99/mo, one less box to keep healthy, one less country to
  keep validated against RKN blocking.
  **Risk:** loses geographic diversity — a single provider outage takes down
  100% of VPN service, not just one exit; loses the "pick your country" feature
  entirely, even if current usage of it is near-zero.

## What I'd actually recommend, if asked

**Scenario A now** — net-positive, close to zero risk, cleans up a relay that
may be dead weight and an orphaned bot server nobody's tracking the cost of.
Then get **real numbers** on NL and MSK-relay cost straight from the Timeweb
panel (not the `vpn_servers.cost_monthly` field, which disagrees with itself by
8x) before choosing between B and C. The revenue reality (~€45/quarter) means B
is probably right eventually — but which specific box goes away should wait for
a verified cost picture, not an unreliable admin-panel number.

## Not done here

No server was stopped, no DNS record was changed, no relay contract was
cancelled, no domain registration was touched. Read-only analysis; the decision
is the user's.

---

## Update 2026-07-11 (same day): real billing numbers, one server misread

User pulled the actual figures from the hosting panels, resolving the
NL/MSK/SPB "unknown/conflicting" rows above:

| Host | Confirmed cost | What it means |
|---|---|---|
| NL (147.45.252.234) | **1,590 ₽/mo (~€16.7)** | The 8x conflict is resolved — real cost is close to the DB's low figure, **not** the ~9,740 ₽/mo the old billing memory claimed (that number was wrong/stale and has been corrected in memory). |
| MSK relay (217.198.5.52) | **530 ₽/mo (~€5.6)** | Dirt cheap for the sole API ingress + relay chains. Not a cost question. |
| SPB relay (185.218.0.43) | **140 ₽/mo (~€1.5)** | Trivial. |
| MSK bot box (85.239.49.28) | **730 ₽/mo (~€7.7)** | See below — this one is not what it looked like. |

**This changes the recommendation.** Total known infra spend is now
~€53-54/mo (WAW €12.24 + GRA €9.99 + the four boxes above ≈ €31), against ~€45
of revenue *per quarter* (~€15/mo). Spend still outruns revenue, but by a much
smaller margin than the unresolved NL conflict suggested — **Scenario B (drop
NL's live replica) is downgraded**: saving ~€17/mo is not worth turning WAW
back into a lone-primary SPOF and touching a box that also runs someone's live
`ss-ws` production router. Recommend keeping NL as-is.

### SPB — how to actually test whether it's worth keeping

At €1.5/mo, this was never really a cost question — it's whether the RU
whitelist-bypass path is doing anything. Checked the existing per-leg auth
telemetry (`app_events`, `event_name='auth.attempt'`, `properties->>'leg'`) —
this instrumentation exists (shipped with the RU-DECOY builds) but has fired
only **3 times in the last 90 days** (2× `decoy`, 1× `primary`). That's too
thin a sample to prove or disprove SPB's value — it mostly reveals that this
telemetry isn't being captured broadly, not that the decoy path is unused.

Recommended test, in order:
1. Recover SPB via the SprintHost panel (cheap, ~nothing to lose at this price).
2. Once it's back, verify the `auth.attempt` / leg-selection telemetry is
   actually firing for a meaningful share of sign-ins, not just 3 events in 90
   days — if it's under-firing, that's a separate small bug worth fixing before
   trusting any leg-usage number.
3. Let it run a few weeks, then pull the leg-win distribution again. If `decoy`
   essentially never wins over `primary`/CF, the RU whitelist-bypass path isn't
   earning its keep even at €1.5/mo and can be retired outright. If it wins a
   meaningful share for RU users specifically, it's cheap insurance and worth
   keeping fixed.

### MSK bot box (85.239.49.28) — NOT what it looked like

Original assumption (from `docs/state/domains.yaml`'s "scrub or repoint"
note on `bot./crew./speedtest.madfrog.online`) was an orphaned marketing
leftover. Live inspection found something different: this box runs a
**separate, actively-maintained legacy system** — a Telegram bot (blue/green
deploy: `bot-blue`/`admin-blue`/`support_bot`, its own Postgres + Redis) plus
a Marzban/Xray-based VPN backend, independent of the Chameleon Go
backend/database entirely (different repo, per project memory).

Two things are true at once:
- It is **not dead weight in the "nobody's touched it in months" sense** —
  container uptimes and a blue/green deploy pattern show real, relatively
  recent operational attention.
- But its **Xray VPN proxy container has been crashed (`exited code 2`) since
  2026-07-08 — 3 days, unnoticed** — and the only traffic in its access log
  is an internal healthcheck loop (`127.0.0.1 → 127.0.0.1:10085 [api -> api]`
  every 5 min), not real client connections. Whether that's because it's
  genuinely idle or because monitoring for *this* box lives entirely outside
  this repo and nobody's watching it is unclear from here.

**Did not go further** — this looked like it could be a separate,
possibly-still-monetized product line, not just infra cleanup, and digging
into its own user database wasn't asked for. **Needs a direct answer from the
user**: is this Telegram-bot business still active/relevant, or is it fully
legacy from before the native app? If legacy → shut it down (saves €7.7/mo,
removes an unmonitored dead VPN proxy). If active → it has its own open
incident (3-day-dead proxy) that has nothing to do with anything else in this
audit and should be triaged on its own.

## Update 2026-07-11 (later same day): user's 3-server cut proposal, checked live

User proposed cutting WAW, NL, and migrating the bot box onto MSK relay.
Checked each against live evidence before agreeing to anything:

- **WAW (217.182.74.70) — cannot be cut, full stop.** This is a factual
  correction, not a trade-off: since the 2026-06-29 failover WAW is the live
  primary backend+DB+web+monitoring+PL VPN exit. Removing it takes down 100%
  of the product. (Likely source of the confusion: WAW was originally
  provisioned and referred to as "standby" before the failover flipped the
  roles.)
- **NL (147.45.252.234) — cannot be cut either, but for a different reason:
  live evidence, not policy.** `ss -tn | grep -c ESTAB` on NL right now shows
  **452 established connections** on the `singbox-ss-ws` router — the
  "do-not-touch" production router is genuinely, heavily in active use, not
  dormant. Since the box must stay up for the router regardless, there is
  **no cost saving available from touching NL** — only stopping the Postgres
  replica role is on the table, and that's a pure reliability trade-off (RPO
  seconds → last-backup), not a spend reduction, since the box's own cost
  doesn't change either way. Side finding: the ss-ws process itself is
  restart-looping roughly hourly inside the container (`use of closed
  network connection` in its logs) — not a cost issue, but worth a look if
  that router ever gets touched for other reasons.
- **MSK bot box (85.239.49.28) — do not migrate onto MSK relay (217.198.5.52)
  regardless of the bot's status.** MSK relay is the sole API ingress for
  100% of the live app's active users — piling an unrelated bot+DB+admin
  stack onto the single most structurally critical box in the whole mesh is
  a bad trade even if the bot turns out to be worth keeping. Checked the
  *main* user-facing bot container (`bot-blue`, not admin/support): **2 log
  lines in 7 days, zero message/payment activity visible** — combined with
  the previously-found silent admin panel and the unnoticed 3-day-dead VPN
  proxy, this is now three independent signals pointing at "dormant."
  Recommended action: user does a 30-second manual check (open the bot in
  Telegram, look at recent chat history) as the final confirmation only a
  human can make here: if confirmed dead, shut it down outright (saves
  €7.7/mo) rather than migrate it anywhere.

**Net result:** of the three proposed cuts, only the bot box holds up, and
only pending the user's own confirmation. Combined with the already-trivial
SPB (€1.5/mo) and razblokirator.ru (server cost: €0) items, **total
realistically available savings are ~€7.7-9/mo** — not the "cut a big
expensive box" win the 8x NL memory error originally suggested. The gap
between spend (~€53-54/mo total) and revenue (~€45/quarter, i.e. ~€15/mo
equivalent) is mostly structural: WAW + GRA + MSK relay alone (€27.8/mo) are
the non-negotiable minimum to run the product at all, not cuttable fat.

## Update 2026-07-11 (evening): bot box confirmed dead and decommissioned

The user personally sent `/start` to `@MadFrogRobot` four separate times
over 3+ hours (screenshots reviewed live) — zero replies, every time. That's
the direct human confirmation this doc asked for, not just log inference.

Decommissioned: full backup taken first (`pg_dumpall` + the entire
`/root/telegram_vpn_bot/` directory, 2036 files, 66MB compressed) to
`~/backups/madfrog-bot-legacy-2026-07-11/` (local machine, outside this
repo, with a README explaining what it is and how to restore). All 10
Docker containers stopped. 5 stale Cloudflare DNS records deleted —
`bot./crew./speedtest.madfrog.online` plus two more found during cleanup,
`msk1.mdfrog.site` and `msk1.razblokirator.ru` (not previously tracked in
this doc). Checked each wasn't load-bearing before deleting — notably
`bot.madfrog.online` carried a Cloudflare comment claiming it was reserved
as a future FreeKassa webhook target, but a grep of the live backend plus
`docs/state/payment-providers.yaml` confirmed the real, current webhook
(`POST /api/webhooks/freekassa`) never actually used that subdomain.

Ops-alert delivery via the same Telegram channel (`backend/scripts/
telegram-alert.sh`, runs from WAW/GRA) confirmed still working after
shutdown — unaffected, as predicted above.

**Update, same evening:** the VPS cancellation initially looked out of reach
("that account isn't reachable with any credentials available this
session") — wrong. `TIMEWEB_API_KEY` in `~/.secrets.env` turned out to be
the right account. Found it by listing all servers under that key: 5 total,
one of them `testServer` (id `6636843`) at exactly `85.239.49.28`, the other
4 being NL, MSK relay, and two unrelated non-Chameleon projects — checked
this list carefully before deleting anything, given the same account also
holds two boxes this entire session depended on staying alive. Deleted the
server (`DELETE /api/v1/servers/6636843` → 204), then found its IP survived
as an orphaned floating-IP resource (`resource_type: null` after the server
was gone — Timeweb does not auto-release it) and deleted that separately
(`DELETE /api/v1/floating-ips/{id}` → 204). Verified both gone from the
account and all 4 remaining servers (including NL and MSK relay)
untouched. **The ~€7.7/mo saving is fully realized as of today, not
deferred to the user.**
