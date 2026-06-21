---
date: 2026-06-21
type: audit + living-loop
scope: product maturity — recurring revenue / retention / UX-UI / product-completeness / kostyli
method: 4-agent parallel audit (retention, UX/UI, completeness, tech-debt) on top of the 2026-06-17 full-service audit
status: LIVING DOCUMENT — the "весь путь изменений" change journal. Append to §6 every iteration; never rewrite history.
supersedes_nothing: complements docs/audits/2026-06-17-full-service-audit.md (reliability/security/infra)
---

# MadFrog VPN — Product-Maturity Loop

> **Why this exists.** The owner is in production with paying customers but wants to *advertise* and earn
> **recurring** revenue — not "sell a subscription once and never see the user again". The 2026-06-17 audit
> covered reliability/security/infra. This one adds the lens that audit barely touched: **why people pay
> once and leave**, plus **UX/UI**, **product completeness**, and **kostyli/tech-debt**. It is a *living*
> document: §5 is the prioritized registry, §6 is the append-only journal of every change we make.

---

## 1. The headline (read this first)

**The product is monetized as a one-shot purchase, end to end — by design, at every layer.** "Buy once, never
come back" is not a UX accident; it is the literal behavior of the monetization stack:

1. **All 4 Apple IAPs are `NON_RENEWING_SUBSCRIPTION`** (`docs/state/app-store.yaml:117`, ADR 0005). Apple
   never auto-charges — the user must *manually re-buy* every cycle. ADR 0005 itself predicts a **30-50% LTV
   drop** vs auto-renew and says "marketing must remind users to renew" — that reminder system **was never built**.
2. **FreeKassa (the ONLY rail actually making money — 12 pays ~3489₽; Apple IAP = 0)** has **no recurring
   billing, no saved card, no failed-payment retry**. Every RU renewal = re-enter email, pick a method, pay in a
   browser. Maximum-friction re-purchase for 100% of real revenue.
3. **No lifecycle engine anywhere.** There is no job that scans "expiring in 3 days / expired yesterday" and
   sends a push or email. The push sender, the email sender, and the audience labels all exist — they are just
   **not wired to a scheduler**. A lapsed user gets *zero* automated touch.
4. **Churn is invisible.** EventTracker measures acquisition only (no `trial_expired`, `subscription_renewed`,
   `resubscribe`). The owner literally cannot *see* churn or renewal rate today.

On top of that, the **UX bookends repel**: a brand-new user hits a sign-in wall with no onboarding/trust moment
and a fake hand-drawn Google "G"; the free trial (best hook) is a tiny grey underline; once connected the app
never *proves* it's working (no IP, no location); and the paywall — the revenue moment — is a bare price list
with no pitch and no mention of the trial. *"Polished in the middle, limping at the edges."*

And the product is **missing the #1 VPN trust feature**: there is **no kill switch** (`includeAllNetworks()`
returns `false`, `ExtensionPlatformInterface.swift:160`) — when the tunnel drops, traffic silently leaks.

**Through-line:** core engineering is solid; the gaps are *commercial maturity* (recurring billing + lifecycle),
*trust* (kill switch, proof-of-protection, onboarding), and a *bare paywall*. The good news: the single
highest-ROI fix — the **lifecycle re-engagement engine** — is backend-only, ships with no App Store review, and
reuses parts that already exist.

---

## 2. The four tracks

| Track | Theme | Owner question it answers |
|---|---|---|
| **A. Recurring revenue / retention** | renewal billing, lifecycle, win-back, churn metrics | "how do I earn every month, not once?" |
| **B. UX/UI & trust** | onboarding, paywall pitch, proof-of-protection, polish, L10n | "why does it feel unfinished / limping?" |
| **C. Product completeness** | kill switch, data-usage, IP display, manage-sub, reminders | "what makes it a *real* product?" |
| **D. Kostyli / tech-debt / infra safety** | deploy/restore safety, dual server-selection model, watchdogs | "what will break / is held by tape?" |

## 3. How we run this loop
- Each iteration picks the **highest-leverage item(s)** from §5, implements with a test (per decision 0009),
  verifies, and logs an entry in §6 with date / what / why / files / result.
- **No-build server/admin items first** (ship same-day) → then **app-build batches** (ride a TestFlight build).
- High-risk changes to working prod code are flagged and confirmed with the owner before touching.
- When an item completes, mark it `DONE` in §5 and move the matching roadmap entry.

## 4. Method & provenance
4 parallel read-only audit agents on 2026-06-21 (retention, UX/UI, product-completeness, kostyli), each told to
build on — not repeat — the 35-agent 2026-06-17 audit. Every anchor below was grep/Read-verified by an agent.
Reliability findings (DNS/oom/refresh-token/SSE) live in the 2026-06-17 doc and are not duplicated here.

---

## 5. Problem registry (prioritized)

Severity = impact on the owner's goal (recurring revenue + advertisable quality), not raw bug severity.
`build?` = needs an App Store / TestFlight build (slow) vs server/admin deploy (same-day).

### Track A — Recurring revenue / retention

| ID | Sev | Anchor | Costs us | Fix | Effort | build? | Status |
|---|---|---|---|---|---|---|---|
| `A1-lifecycle-engine` | **P0** | `cmd/chameleon/main.go:391` (enforcement sweep notifies nobody); `push/push.go` + `email/resend.go` only manual | No expiry reminder / trial nudge / win-back anywhere → lapsed users get zero touch | Daily sweep → segment `expiring_soon`/`expired_recent`/`expired_winback` → push + email (senders + audiences already exist) | M | **no** | **BUILT (disabled) 2026-06-21** (iter 2; new `internal/lifecycle` + mig 027 + dry-run; deploys dormant; **owner: review copy → set `lifecycle.enabled`**) |
| `A2-auto-renew-iap` | **P0** | `app-store.yaml:117`; ADR 0005; `SubscriptionManager.swift:16,26` | Non-renewing = manual re-buy; ADR predicts 30-50% LTV loss; blocks Family Sharing + StoreKit win-back/intro offers | New subscription group w/ auto-renewable product IDs; honor `DID_RENEW`/`EXPIRED`/`GRACE` ASN | L | yes | OPEN (roadmap had it `deferred`, data-gate now satisfied) |
| `A3-freekassa-recurring` | **P0** | `payments/freekassa/client.go` (one-shot CreateOrder only) | 100% of real revenue is on the rail with no recurring/saved-card/dunning | Saved-card / СБП rebill token + server-side renewal scheduler | L | no | OPEN |
| `A4-asn-churn-signals` | P1 | `payments/subscription_notification.go:110` (`EXPIRED`/`DID_FAIL_TO_RENEW`/`GRACE` → log+drop); no `auto_renew_status` column | Apple's involuntary-churn signals discarded; can't segment voluntary vs involuntary churn | Persist `auto_renew_status`+`expiration_intent`; act on `DID_FAIL_TO_RENEW` | M | no | **DEFERRED** (iter 4: `apple` pkg doesn't parse renewalInfo + these events don't fire for NON-renewing subs — becomes useful with A2; low value now) |
| `A5-proactive-paywall` | P1 | `MainView.swift:125`; paywall only from chips `MainViewNeon.swift:120,416`,`Calm:330` | Paywall seen by 9/257 connecters → 3.8% paid; trial→paid moment has no surface | One-time paywall on trial→expired transition (state-tracked) | S | yes | OPEN (roadmap PAYWALL-FUNNEL-TRIGGER over-optimistically "addressed") |
| `A6-expiry-warning-ui` | P1 | `MainViewNeon.swift:446`,`Calm:355` (countdown is grey subtitle text only) | Most persuasive moment (trial ends tomorrow) is invisible | Banner + CTA when `daysLeft<=3`; distinct trial vs paid copy | S | yes | OPEN |
| `A7-client-reengagement` | P1 | no `UNCalendar/TimeInterval` trigger for expiry; `winBack`/`offerCode`/`promotionalOffer` = 0 hits | No local reminder, no win-back offer client-side; promo engine built but unwired to expired audience + absent from paywall | Local notif on expiry; ship promo field in `WebPaywallView.swift:347`; wire promo→expired campaign | M | yes+wiring | OPEN |
| `A8-annual-savings-framing` | P2 | `WebPaywallView.swift:457` (raw "₽" only) | Annual only ~24%/mo cheaper and UI never shows it → users pick highest-churn monthly | Compute per-month + "save X%"; widen annual discount | S | yes | **DONE 2026-06-21** (iter 6; pure `PlanPricing` + per-month + "выгода X%" badge, RU/EN; rides CI build). Widening the actual discount is an owner pricing call. |
| `A9-churn-instrumentation` | P2 | `EventTracker.swift` (acquisition events only); gate `AppState.swift:1372` fires no event | Owner cannot see churn / renewal / trial-conversion rate → advertising blind (no LTV/CAC) | Emit `subscription.expired`/renewed/resubscribe + admin churn dashboard | M | yes+admin | **DASHBOARD DONE 2026-06-21** (iter 4; admin shows active-subs / churn-7d-30d / trial-conversion% / repeat-purchase% from existing data). Client event-emit half still rides a build. |
| `A10-freekassa-refund` | P2 | no FK refund handler; `MarkRefundedAndReconcile` Apple-only (`credit.go:209`) | Refunded RU payment keeps VPN access (small leak on the revenue rail) | FK refund webhook → MarkRefundedAndReconcile | S | no | **DEFERRED** (iter 4: FK pkg exposes no refund/cancel notification type — needs FreeKassa's refund-callback spec; owner to confirm FK even pushes refunds) |
| `A11-trial-reinstall-hole` | P3 | `auth.go:635`; TRIAL-ABUSE-REINSTALL | Delete+reinstall → fresh trial (3 of 347 — tiny) | install_secret/DeviceCheck gate | M | no | DEFER-until-grows (correct) |

### Track B — UX/UI & trust

| ID | Sev | Anchor | User feels | Fix | Effort | build? | Status |
|---|---|---|---|---|---|---|---|
| `B1-paywall-no-pitch` | P1 | `PaywallView.swift:118,223` (price list, no bullets/badge/savings); two divergent paywalls | Revenue screen is unpersuasive | Benefit bullets + best-value badge + per-month math; restate trial on CTA; frame "no auto-renew" as trust; parity Apple↔Web | M | yes | **DONE 2026-06-21** (iter 9; shared `PaywallBenefits` value-pitch on BOTH paywalls; "no auto-renew = no surprise charges" framed as trust; web savings badges from A8). REMAINING refinement: best-value badge on Apple `PlanCard`. |
| `B2-onboarding-no-trust` | P1 | `OnboardingView.swift:33` (sign-in wall, no intro); trust = 3× 11pt pills | Can't evaluate before handing over identity; drop-off | 2-3 page intro (what/why-trust/free-trial) before auth | M | yes | OPEN |
| `B3-trial-cta-buried` | P1 | `OnboardingView.swift:108,303` (guest = 13pt grey underline) | Best conversion hook is least visible | Promote "Start free — no account" to a real button | S | yes | OPEN |
| `B4-no-proof-of-protection` | P1 | `MainViewCalm.swift:135`,`Neon:150` (timer only, no IP/location) | No felt confirmation VPN works | Show apparent IP / "you appear in X" on connect | M | yes | OPEN (= C3) |
| `B5-support-chat-russian` | P1 | `SupportChatView.swift:64,120` (hardcoded RU); `AnnouncementView.swift:65,98` | EN users hit raw Russian exactly when frustrated | Move strings to Localizable.strings | S | yes | **DONE 2026-06-21** (iter 7 support-chat + iter 8 AnnouncementView cta/dismiss/badges via `String(localized:)`; en=ru=296 keys) |
| `B6-offline-vs-disconnected` | P2 | Neon `home.neon.exposed`="OFFLINE" vs Calm "Disconnected" | "OFFLINE" implies no internet, not "exposed" | Unify to accurate pair ("Not connected"/"Exposed — tap to protect") | S | yes | **DONE 2026-06-21** (iter 7; en "OFFLINE"→"UNPROTECTED" — accurate: online-but-exposed, not no-internet) |
| `B7-google-logo-fake` | P2 | `OnboardingView.swift:330` (bold letter "G") | Looks cheap/placeholder on first screen | Official multicolor G asset (also a Google requirement) | S | yes | OPEN |
| `B8-restore-discoverability` | P2 | restore only on paywall (`PaywallView.swift:50`), absent from Settings | Reinstalled payer can't find restore → tickets | Add Restore to Account/Settings | S | yes | **DONE 2026-06-21** (iter 10; Account "Restore Purchases" → `app.subscriptionManager.restorePurchases()` + `refreshConfig` (StoreKit + FreeKassa cross-device) + result alert) |
| `B9-account-sparse` | P2 | `AccountView.swift:14` (system List, UUID username, no provider/email/manage) | Feels unfinished vs themed app | Theme it; show provider/email; Manage-sub link | S/M | yes | OPEN (manage-sub = C4) |
| `B10-web-paywall-handoff` | P2 | `WebPaywallView.swift:347` (external Safari, no return guidance) | RU users think payment failed → abandon | "Waiting for payment" pending state on return | S/M | yes | OPEN |
| `B11-list-vs-card-mismatch` | P2 | server picker + Account use system `List`; rest uses themed cards | Inconsistent surface = "limping" | One list idiom; theme system Lists | M | yes | OPEN |
| `B12-brand-fonts-unshipped` | P2 | `Theme.swift:65` (`displayFontName:nil` "for now") | Signature theme uses system fonts | Ship intended fonts or delete dead config | S/M | yes | OPEN |
| `B13-theme-picker-dead` | P2 | `ThemePickerView.swift:3` vs `MadFrogVPNApp.swift:58` (`hasSelected` never used) | (dev trap) half-built first-run flow is dead code | Wire it or delete + fix comments | S | yes | OPEN |
| `B14-a11y-gaps` | P2 | connect button no a11y label (`Calm:136`,`Neon:331`); fixed font sizes; <44pt taps | Poor VoiceOver / Dynamic Type | a11y label+value on connect; relative sizing; 44pt targets | M | yes | OPEN |
| `B15-stale-mocks-copy` | P3 | `ThemePickerView.swift:113` ("DE-1·24ms" retired DE); `EmailSignInView.swift:69` ("email" not localized) | Small "unfinished" tells | Live mock; use localized placeholder | S | yes | **DONE 2026-06-21** (iter 8; "DE-1·24ms"→"Netherlands·24ms"; email prompt → `L10n.Magic.emailPlaceholder`) |
| `B16-auto-exit-country` | P3 | `MainView.swift:560` (Auto shows 🌍, hides resolved country) | Auto users don't know exit country | Surface resolved country in subtitle on connect | S | yes | OPEN |

### Track C — Product completeness (table-stakes)

> Already shipped & solid (do NOT sandbag): on-demand auto-connect (`VPNManager.swift:141`), Control Center
> toggle (`MadFrogControlWidget.swift:13`), home/lock widgets (`StatusWidget.swift:49`), Shortcuts/Siri
> (`VPNControlIntents.swift:164`), per-server ping, disconnect notif + auto-reconnect, delete-account, EN+RU
> L10n, macOS menu bar.

| ID | Sev | Anchor | Why it matters | Fix | Effort | build? | Status |
|---|---|---|---|---|---|---|---|
| `C1-kill-switch` | **P0** | `ExtensionPlatformInterface.swift:160` (`includeAllNetworks=false`); PLANNED later#features | #1 VPN trust feature; absence = silent leak on drop → review-bombs | `includeAllNetworks` + persistent on-demand (not just a toggle) | M | yes | OPEN |
| `C2-data-usage-stats` | P1 | ABSENT in UI; stats exist server-side; partial PLANNED LAUNCH-09 | Top-3 reason users open a VPN app; absence feels like a toy | Render bytes up/down + session total from existing stats | M | yes | OPEN |
| `C3-current-ip-location` | P1 | ABSENT | The "is it working?" check; absence → support + distrust | Echo endpoint + a home row | S/M | yes | OPEN (= B4) |
| `C4-manage-sub-deeplink` | P1 | ABSENT (no `showManageSubscriptions`) | Easy-to-cancel = trust; reduces chargebacks; Apple-friendly | StoreKit `showManageSubscriptions` sheet | S | yes | OPEN |
| `C5-expiry-reminder` | P1 | ABSENT (date shown `AccountView.swift:87`, no reminder) | For non-renewing IAP this IS the renewal engine | Local notif on expiry date (+ APNs via A1) | S | yes | OPEN (pairs with A1/A7) |
| `C6-device-management` | P2 | ABSENT (register exists, no list/revoke UI) | Expected account hygiene; hides abuse | Backend list+revoke + UI (SPA has user view) | M | yes | OPEN |
| `C7-split-tunneling` | P2 | ABSENT (`NEAppRule`); routing modes partially substitute | Power-user retention; RU smart-routing softens it | per-app rules | L | yes | OPEN |
| `C8-live-activity` | P2 | ABSENT; PLANNED LAUNCH-10 | "Premium" signal | ActivityKit session | M | yes | OPEN |
| `C9-referral` | P2 | ABSENT (not even on roadmap) | Cheapest growth+retention loop | backend + invite UI | M/L | yes | OPEN |
| `C10-ipad-layout` | P3 | ABSENT; PLANNED REFAC-03 | iPad gets blown-up phone UI | NavigationSplitView / size classes | M | yes | OPEN |
| `C11-change-email-export` | P3 | ABSENT (delete exists) | GDPR export nicety | flows | S each | yes | OPEN |

### Track D — Kostyli / tech-debt / infra safety

| ID | Sev | Anchor | Failure mode | Fix | Effort | Status |
|---|---|---|---|---|---|---|
| `D1-deploy-no-error-stop` | **P0** | `backend/deploy.sh:335` (`psql <f 2>/dev/null && echo Applied`; 4 migrations no BEGIN/COMMIT) | Failed migration is invisible, deploy reports success → partial apply on sole DB node | `-v ON_ERROR_STOP=1`, drop `2>/dev/null`, fail-fast, wrap migrations in tx | S/M | **DONE 2026-06-21** (iter 1; verified migrations idempotent first) |
| `D2-restore-broken` | **P0** | `infrastructure/restore.sh:20` reads `-Fc`; real backup is `pg_dump|gzip` `.sql.gz` (`scripts/db-backup.sh`) | Documented DR path **cannot read real backups**; no B2 pull; no drill — on a single-NL SPoF | Make restore consume `.sql.gz` (`gunzip|psql`) + B2 pull + periodic drill | M | **DONE 2026-06-21** (iter 1; rewrote restore.sh; also fixed wrong `backend`→`chameleon` service) |
| `D3-connect-watchdog-40s` | P0 | `AppState.swift:1389` (18+3+1+18 ≈ 40s, self-documented) | Violates 30s mandate; 40s spinner before error | Retune ≤30s (e.g. 13×2+grace); name the magic 18s | S | OPEN |
| `D4-ext-start-no-watchdog` | P0 | `ExtensionProvider.swift:447` (`startOrReloadService` blocking, no timeout) | libbox hang → `startTunnel` never resolves | Race against deadline → completionHandler(error) | M | OPEN |
| `D5-dual-server-selection` | P1 | `ConfigStore.swift:127,295` + `PathPicker.swift:188`; **9** country tables | Root of FR-SELECT / UI-FLAG-HOME / COUNTRY-PICK-STICKY bug class; new country = up to 9 edits | One `Country` registry + `ServerSelection` enum parsed once at boundary (retires SRV-DYNAMIC) | L | OPEN |
| `D6-neon-badge-AUTO` | P1 | `MainViewNeon.swift:213` (leaf-only lookup → "AUTO" on country pin) | Dual-model fix half-applied (Neon path missed) | Check `app.servers.countries` before leaf / use shared helper | S | OPEN |
| `D7-geoip-negative-cache` | P1 | `geoip.go:61` (caches zero Result 24h on any failure; unbounded map) | Transient/ratelimit pins blank country/city 24h; backfill blanks | Cache only `status==success`; short negative TTL; bound map | S | **DONE 2026-06-21** (iter 3; 10min negative TTL + 50k cap + evict; +5 tests, 8/8 green) |
| `D8-relay-drift-manual` | P1 | `infrastructure/{msk,spb}-relay/README.md` (diff is manual) | Off-box edit not pulled → rebuild restores stale config (DR gap) | Scheduled drift-check → telegram alert | M | OPEN |
| `D9-spb-password-arg` | P1 | `spb-relay/README.md:13` (`sshpass -p "$PW"`) | Password in process args (`ps`/`/proc`); only node not on keys | Key auth, or `sshpass -e`/`-f` | M | OPEN |
| `D10-watchdog-hardcoded-tag` | P1 | `scripts/singbox-watchdog.sh:8` (`v1.13.6-userapi` hardcoded ×2) | Tag bump → watchdog resurrects stale image during outage | Source tag from shared `.env` | S | **DONE 2026-06-21** (iter 1; new `scripts/singbox.env`, both scripts source it) |
| `D11-admin-204-crash` | P1 | `clients/admin/src/lib/api.ts:24` (always `res.json()`); `nodes.go:1042` returns 204 | DeleteServer succeeds but SPA throws "delete failed" | `if status===204 return undefined` | S | **DONE 2026-06-21** (iter 1; +4 vitest tests, 14/14 green, tsc clean) |
| `D12-install-no-set-e` | ~~P1~~ | `infrastructure/deploy/install.sh:16` | — | — | — | **FALSE FINDING** (install.sh already has `set -euo pipefail` at :16; agent looked at wrong file) |
| `D13-realtraffic-suppressor-dead` | P1 | `RealTrafficStallDetector.swift:379` (`addCloseEvent` never called) | False-positive guard silently disabled | Wire from log-ingest or remove+document | M | OPEN |
| `D14-v2ray-stats-plaintext` | P2 | `stats_v2ray.go:53` (`insecure.NewCredentials()` to GRA) | Per-user usernames+bytes cleartext over internet (ufw-gated only) | TLS / tunnel as defense-in-depth | M | OPEN |
| `D15-settings-raw-json` | P2 | `clients/admin/src/pages/settings.tsx:137` (free-text JSON, no validation) | One typo persists malformed config; 2nd source of truth | JSON.parse guard / deprecate for table API | M | **DONE 2026-06-21** (iter 5; `handleSave` rejects invalid `vpn_servers` JSON before PATCH, all 3 buttons; +tests) |
| `D16-deploy-sed-fragility` | P2 | `backend/deploy.sh:197` (chain of literal `sed -i`) | Template whitespace change → sed matches nothing → wrong default incl SNI | Placeholder template that fails on un-substituted token | M | OPEN |
| `D17-misc-dead-code` | P2/P3 | `APIClient.swift:200` (dead RU filter on retired DE IP); `Constants.swift:14` (dead fallbackBaseURL); `log-monitor.sh:33` (retired DE IP active); dup admin helpers; TZ ambiguity | Maintainability / masks missing RU-detection | delete dead code; extract `lib/format.ts`; pin/label TZ | S each | **PARTIAL — admin dedupe DONE 2026-06-21** (iter 5; `lib/format.ts` countryFlag+relativeTime, removed 2 identical copies + 1; +tests). REMAINING: iOS dead-code (APIClient/Constants — needs iOS build), `log-monitor.sh:33` DE IP, TZ labeling. |
| `RU-AUTH-LEGS-DEAD` | **P0** | `DirectConnection.swift:148` + NL:443=Reality `*.adfox.ru` cert (measured 2026-06-21) | Direct-IP auth fallback legs rejected (wrong cert) → RU sign-in = CF + single decoy; live 1.0.30 = CF alone → flaky login is the real churn driver | Ship 1.0.33 (decoy); next build: drop dead legs + 2nd decoy on SPB + per-leg telemetry; monitor LIVE on MSK | L (cross-cutting) | **SPOF FIXED 2026-06-21** (iter 13; 2nd decoy SPB:8443 LIVE+verified from RU, client races both, monitor tracks both). Remaining: ship a build; drop dead direct-IP legs; per-leg telemetry. |
| `MON-RU-AUTH` | P1 | `infrastructure/monitoring/ru-auth-healthcheck.sh` | (none — new capability) | RU-vantage auth monitor on MSK, cron */5, Telegram alerts on decoy/both-leg death | S | **DONE 2026-06-21** (iter 12; deployed + alert verified) |
| `D18-td-cert-pin-untracked` | P3 | `APIClient.swift:111` (HIGH TODO, no roadmap id) | InsecureDelegate is host-allowlisted + DirectConnection validates chain — residual = cleartext :80 legs (gated for sensitive) | File tracked TD-CERT-PIN; pin server cert fingerprint | S | OPEN (already TD-CERT-PIN in roadmap security) |

---

## 6. Change journal (append-only — the "весь путь изменений")

> One entry per iteration. Format: date · iteration · what · why · files · test · result. Never edit past entries.

### 2026-06-21 · Iteration 0 — Baseline audit
- **What:** Ran a 4-agent parallel product-maturity audit (retention, UX/UI, completeness, kostyli) on top of
  the 2026-06-17 reliability audit. Built this living document: §5 registry (A1–A11, B1–B16, C1–C11, D1–D18 =
  56 items) + §1 headline + §6 journal.
- **Why:** Owner wants recurring revenue + advertisable quality; needed one prioritized map distinguishing the
  *commercial-maturity* gaps from the already-solid engineering.
- **Files:** this doc (new). No code changed.
- **Result:** Baseline established. Headline finding: monetization is one-shot by design at every layer; the
  fastest high-ROI fix is `A1-lifecycle-engine` (backend-only, no App Store review). Awaiting owner's pick of
  starting track/sequence before touching prod code (per agree-first rule).

### 2026-06-21 · Iteration 1 — P0 infra safety + cheap infra debt (branch `product-maturity-loop`)
Owner granted full autonomy ("все сам решай, я спать"). Picked safety-first because subsequent iterations
deploy backend changes — harden the deploy/restore path *before* relying on it. All changes are script/SPA
only, fully verifiable, zero outbound-to-user risk; nothing deployed live yet (on a branch).

- **D1 — deploy hides failed migrations → fixed.** `backend/deploy.sh`: replaced the
  `psql <f 2>/dev/null && echo Applied` loop (no `ON_ERROR_STOP`, stderr discarded, `&&`-list exempt from
  `set -e`) with `psql -v ON_ERROR_STOP=1` + visible stderr + fail-fast `exit 1` that aborts the deploy
  *before* the build/restart steps so new code never runs against a half-applied schema.
  *Why safe:* first verified ALL 25 numbered migrations are idempotent (IF NOT EXISTS / DROP IF EXISTS /
  ON CONFLICT DO NOTHING / WHERE NOT EXISTS) and none use `CONCURRENTLY`, so a re-run after a fix is safe and
  this can't break a currently-working deploy. *Verify:* `bash -n` OK.
- **D2 — restore.sh can't read real backups → rewrote.** Real backups are plain `pg_dump|gzip` (`*.sql.gz`,
  no `--clean`) but the script ran `pg_restore` (custom-format only) and stopped a service named `backend`
  that doesn't exist (it's `chameleon`). New `infrastructure/restore.sh`: consumes `*.sql.gz` (`gunzip|psql`),
  `--from-b2 <name>` pulls from Backblaze first, `--list-b2` lists, drop+recreate DB (needed because plain
  dumps carry no DROP), `ON_ERROR_STOP=1`, correct `chameleon` service + `--no-deps`, legacy `*.dump` path
  kept. *Verify:* `bash -n` OK, +x restored. **Next:** run an actual restore drill on NL (deferred — needs box).
- **D10 — hardcoded sing-box image tag → single source.** New `backend/scripts/singbox.env`
  (`SINGBOX_IMAGE=...`); `singbox-run.sh` + `singbox-watchdog.sh` now source it with the literal as fallback.
  Bump one line on a fork rebuild → watchdog can no longer resurrect a stale image. Backward compatible.
- **D11 — admin 204 crash → fixed + tested.** `clients/admin/src/lib/api.ts`: return `undefined` on HTTP 204
  before `res.json()` (DeleteServer no longer surfaces a false "delete failed" toast). Added
  `src/lib/api.test.ts` (4 tests: 204, 200-body, 4xx detail, 5xx-masked). *Verify:* `vitest run` 14/14 green,
  `tsc --noEmit` clean.
- **D12 — FALSE FINDING.** `infrastructure/deploy/install.sh` already has `set -euo pipefail` (:16). No change.

Result: 5 infra-safety items closed (4 fixed + 1 false), the two scariest DR landmines on the single DB node
neutralized. Files: `backend/deploy.sh`, `infrastructure/restore.sh`, `backend/scripts/{singbox.env,singbox-run.sh,singbox-watchdog.sh}`, `clients/admin/src/lib/{api.ts,api.test.ts}`.
Next iteration: **A1 lifecycle re-engagement engine** (backend; built DISABLED so it can't blast real users
overnight — owner reviews copy + flips it on).

### 2026-06-21 · Iteration 2 — A1 lifecycle re-engagement engine (built DISABLED)
The headline business fix: the direct counter to "buy once, never come back". A daily sweep finds users whose
subscription/trial is lapsing or recently lapsed and sends a push + email reminder, **once per cycle**.

- **Why disabled by default:** enabling it sends real push + email to real customers. It deploys *dormant*
  (`lifecycle.enabled=false`); with `dry_run=true` it logs exactly who WOULD be contacted and sends nothing.
  The owner reviews reach + copy, then flips it on. Building it on a branch overnight without a kill switch
  would risk blasting the whole base with un-reviewed copy — not acceptable unattended.
- **What was built:**
  - `backend/migrations/027_lifecycle_reminders.sql` — idempotency table; unique (user_id, kind, expiry_ref)
    so each reminder fires once per subscription cycle (re-subscription = new expiry_ref = eligible again).
  - `backend/internal/db/lifecycle.go` — `LifecycleCandidates` (active users in a window, not-yet-reminded,
    NULL-expiry excluded per REFUND-NULL-EXPIRY-GATE, paid-vs-trial via the payments EXISTS) +
    `RecordLifecycleReminder` (ON CONFLICT DO NOTHING).
  - `backend/internal/lifecycle/lifecycle.go` — pure `Window(kind,now)` + `Compose(kind,paid,lang,cta)`
    (RU+EN, renew-vs-convert copy, branded email) + `Engine.Sweep` (push to all tokens w/ 410-prune reusing
    `push.ErrBadToken`, email if present, then record; dry-run logs only; ctx-cancellable).
  - `config.LifecycleConfig{Enabled,DryRun,DeepLink}` + `cmd/chameleon/main.go` daily ticker (first run ~1min
    after start, then 24h), gated on `cfg.Lifecycle.Enabled`.
- **Window choice:** "expiring" = next **24h** (not 72h) so a freshly-registered 3-day-trial user isn't told
  "expires in 3 days" on day 0 (unit-tested: `TestExpiringWindowExcludesFreshTrial`).
- **Verify:** `go build ./...` OK · `go vet ./...` OK · `gofmt` clean · `internal/lifecycle` tests green
  (Window ranges, fresh-trial exclusion, all 18 Compose variants non-empty + CTA present, paid/trial framing,
  lang default→RU). DB-deploy only, **no app build**.
- **Known gaps (logged):** (1) **TEST-LIFECYCLE-SWEEP** — the `LifecycleCandidates` SQL + `Engine.Sweep`
  wiring need a test-DB integration harness (pure logic is covered). (2) per-user **locale not persisted** →
  copy defaults to RU; EN selectable once a locale column exists. (3) email "from" reuses the Resend config.
- **How the owner enables it (after review):** add to the NL backend config YAML:
  ```yaml
  lifecycle:
    enabled: true
    dry_run: true            # start here — watch logs "lifecycle: DRY-RUN would notify"
    deep_link: "https://madfrog.online/app"
  ```
  Then `cd backend && ./deploy.sh nl`, watch logs a day, then set `dry_run: false`. (Config defaults to
  disabled, so the code can ship in any earlier deploy harmlessly.)

Result: the single highest-ROI retention mechanism exists, tested, and ready — gated behind one flag so it
can't fire un-reviewed. Files: `migrations/027_lifecycle_reminders.sql`,
`internal/{lifecycle/lifecycle.go,lifecycle/lifecycle_test.go,db/lifecycle.go,config/config.go}`,
`cmd/chameleon/main.go`.
Next iteration: backend retention leaks that need no app build — **A10** (FreeKassa refund handler) and
**A4** (persist Apple ASN churn signals), then **D7** (geoip negative-cache).

### 2026-06-21 · Iteration 3 — D7 geoip negative-cache self-heal
- **What:** `backend/internal/geoip/geoip.go`: `fetch` now returns `(Result, ok bool)`; `Lookup` caches a
  SUCCESS for 24h but a FAILURE (network error / non-200 / rate-limit / status!=success) for only 10min
  (`negativeTTL`), so a transient ip-api outage or a sign-up burst hitting the 45 req/min free tier no longer
  pins blank country/city for a full day. Added a 50k-entry cap + `evictExpiredLocked` (the map was unbounded).
- **Why it matters for the goal:** country/city is what feeds analytics, audience targeting, and the FreeKassa
  allowlist — blank-for-24h corrupts exactly the data the owner needs to advertise + segment.
- **Verify:** added `baseURL` seam for httptest; +5 tests (success long-TTL, rate-limit→negative-TTL,
  status-fail→negative-TTL, eviction) → `internal/geoip` 8/8 green; build/vet/gofmt clean. No app build.

— Pausing active work here (session loop). 4 iterations complete (0 baseline, 1 infra-safety, 2 lifecycle
engine, 3 geoip). All committed on branch `product-maturity-loop`; nothing deployed/enabled (owner reviews).
Next when resumed: **A4** (persist Apple ASN churn signals — auto_renew_status/expiration_intent), **A10**
(FreeKassa refund webhook → MarkRefundedAndReconcile), then the app-build UX batch (B-track) which needs an
iOS build, so those get implemented + unit-tested to ride a build, not submitted unattended.

### 2026-06-21 · Iteration 4 — A9 churn/retention visibility on the admin dashboard
The owner can't decide whether advertising pays back without seeing whether users **come back**. The dashboard
showed acquisition (total/active/DAU) but zero retention. Added it, computed read-only from existing tables.

- **What:** `backend/internal/db/retention.go` — `RetentionStats` (one round-trip): active_subscribers,
  expired_7d, expired_30d, ever_trialed, paid_users, repeat_payers (≥2 completed = the recurring-revenue core),
  trial_converted. Wired into `GetDashboard` (`internal/api/admin/nodes.go`) via a pure `toRetentionDTO` that
  derives **trial_conversion_pct** + **repeat_purchase_pct** (divide-by-zero guarded). New SPA cards on the
  dashboard (`clients/admin/src/pages/dashboard.tsx`): "Активные подписки / Конверсия триала / Повторные
  оплаты / Платящих всего". Graceful-degrade: query error serves zeros, not a 500.
- **Why aligned:** this is the literal "do they come back?" number — the metric the whole loop is about, and
  what the owner needs to compute LTV/CAC before spending on ads.
- **Verify:** backend `go build ./...` + `go vet` + `gofmt` clean; pure-DTO unit tests
  (`internal/api/admin/retention_dto_test.go`: rates, zero-guards, nil, rounding) green; SPA `tsc` clean +
  vitest 14/14; DB integration test (`internal/db/retention_test.go`, `//go:build integration`) compiles and
  asserts the 7 counts against seeded users/payments — runs in CI/Docker (no local Docker, repo's standard).
- **Decisions this iter:** **A4 DEFERRED** — the `apple` package doesn't parse `renewalInfo`
  (auto_renew_status/expiration_intent) and those events don't even fire for NON-renewing subs; it becomes
  worthwhile only alongside A2 (auto-renewable migration). **A10 DEFERRED** — the FreeKassa package exposes no
  refund/cancel notification type; implementing a refund webhook needs FreeKassa's refund-callback spec (owner
  to confirm FK pushes refunds at all). Neither is safe to guess at unattended.

Files: `internal/db/{retention.go,retention_test.go}`, `internal/api/admin/{nodes.go,retention_dto_test.go}`,
`clients/admin/src/pages/dashboard.tsx`.

— **Constraint note for the morning:** local env has **no Docker** (DB integration tests run only in CI) and
**can't compile iOS** (Mac lost the iOS 26 platform; iOS builds via CI). So overnight I'm prioritizing
fully-locally-verifiable backend/admin work; the **B-track UX** items (paywall pitch, onboarding,
proof-of-protection, localize support chat) are high-value but need an iOS build to verify — I'll implement +
unit-test those so they ride your next CI build rather than shipping Swift I can't compile. The biggest
revenue levers (A2 auto-renewable IAP, A3 FreeKassa recurring) need your App-Store-Connect / PSP setup.

Next iteration: a fully-verifiable admin/kostyli win — **D15** (settings.tsx saves raw JSON with no
validation) + **D17 admin** (extract duplicated countryFlag/relative-time into `lib/format.ts` with tests).

### 2026-06-21 · Iteration 5 — admin kostyli: JSON-validation (D15) + dedupe formatters (D17)
Fully-locally-verifiable admin cleanups (the "костыли" the owner explicitly asked about).

- **D15 — settings saved raw JSON unchecked → guarded.** `clients/admin/src/pages/settings.tsx`: a `handleSave`
  now runs `jsonParseError(form.vpn_servers)` and blocks the PATCH with a toast on a malformed VPN-servers
  blob (all 3 Save buttons route through it). No more silently persisting a typo'd config.
- **D17 (admin) — byte-identical helpers deduped → `src/lib/format.ts`.** `countryFlag` existed identically in
  `dashboard.tsx` + `users.tsx`; `relativeTime` in `inbox.tsx`. Extracted to one module (countryFlag now also
  case-insensitive) + `jsonParseError`. Removed all 3 local copies; pages import the shared versions.
- **Verify:** `tsc --noEmit` clean; vitest **22/22** (+8 new in `src/lib/format.test.ts`:
  countryFlag/relativeTime/jsonParseError incl. case-insensitivity, RU time buckets, malformed-JSON).
- **Left intentionally:** `log-monitor.sh:33` DE-label case is harmless dead mapping (no DE host exists) —
  not worth churning a working script. iOS dead-code (APIClient/Constants) stays in D17-remaining (needs build).

Files: `clients/admin/src/lib/{format.ts,format.test.ts}`, `clients/admin/src/pages/{settings,dashboard,users,inbox}.tsx`.

— 6 iterations done (0–5). Branch `product-maturity-loop`; nothing deployed/enabled. Next: continue
fully-verifiable backend/admin items, then prepare the B-track UX batch (implement+unit-test to ride a CI iOS build).

### 2026-06-21 · Iteration 6 — A8 paywall per-month + savings framing (B-track UX, rides CI build)
First B-track item. The FreeKassa paywall showed only raw "599 ₽", so users defaulted to the cheapest visible
number (monthly = highest-churn). Now each card shows an effective **per-month price** + a **"выгода X%"** badge
vs the costliest-per-month (monthly) plan, nudging toward longer commitments.

- **What:** new pure `clients/apple/MadFrogVPN/Models/PlanPricing.swift` (perMonthRub / baselinePerMonthRub /
  savingsPercent — Foundation-only). `L10n.WebPaywall.planPerMonth/planSave` + `webpaywall.plan.per_month` /
  `.save` in en+ru `.strings`. `WebPaywallView` computes the baseline once and each `WebPlanCard` renders the
  per-month line + a savings capsule. Unit test `Tests/UnitTests/PlanPricingTests.swift` (real prices:
  229/30, 599/90, 1099/180, 1999/365 → per-month 229/200/183/164; annual ~28% off).
- **iOS verification model (important):** local Mac can't compile the iOS app (lost iOS 26 platform) and has no
  Docker, so for Swift I verify what I can locally and lean on CI for the full build: **`swiftc -parse` PASSES**
  on PlanPricing.swift, L10n.swift, WebPaywallView.swift, PlanPricingTests.swift (grammar valid); **`plutil
  -lint` OK** on both `.strings`; XcodeGen globs `MadFrogVPN/` + `Tests/UnitTests` so both new files auto-include.
  Full type-check + test run happens in CI `build-for-testing` (repo's standard — iOS unit tests never run
  locally). The SwiftUI "cannot find X in scope" editor diagnostics are single-file isolation artifacts, not
  real errors. Nothing pushed; owner reviews + CI gates before any release.
- **Owner follow-up:** the *actual* discount curve (monthly 229 → annual ~165/mo ≈ 28%) is shallow; widening
  the annual discount to create a stronger pull is a pricing decision for you.

Files: `MadFrogVPN/Models/PlanPricing.swift`, `MadFrogVPN/Models/L10n.swift`,
`MadFrogVPN/Resources/{en,ru}.lproj/Localizable.strings`, `MadFrogVPN/Views/WebPaywallView.swift`,
`Tests/UnitTests/PlanPricingTests.swift`.
Next: more B-track — **B6** ("OFFLINE"→accurate label, pure `.strings`) + **B5** (localize hardcoded RU in
SupportChatView/AnnouncementView), both low-risk + `swiftc -parse`/`plutil`-verifiable.

### 2026-06-21 · Iteration 7 — B6 misleading label + B5 support-chat localization (B-track)
- **B6:** en `home.neon.exposed` "OFFLINE" → **"UNPROTECTED"**. "OFFLINE" implied no internet; the user is in
  fact online but unprotected (VPN off) — the opposite of what "OFFLINE" suggests. (RU "ОТКЛЮЧЕНЫ" was already
  accurate.) Calm's "Disconnected" left as-is (not misleading).
- **B5 (support chat):** the entire diagnostic flow was hardcoded Russian via `.alert("Русский")` literals —
  which Swift treats as `LocalizedStringKey`s with no `.strings` entry, so EN users saw the raw Russian
  fallback when seeking help. Added `L10n.SupportChat` (11 keys) + en/ru `.strings`; replaced all 8
  alert/button/accessibility literals; the WebView "chat unavailable" fallback now uses `String(localized:)`.
  Zero residual RU literals (outside comments).
- **Verify:** `swiftc -parse` OK (SupportChatView.swift, L10n.swift); `plutil -lint` OK (en+ru). Rides CI build.
- **Note:** the `.string` accessor mentioned in L10n.swift's doc-comment was never actually implemented — used
  `String(localized:)` for the one plain-String (HTML) context instead. (Could file a tiny cleanup to drop the
  stale doc line.)

Files: `MadFrogVPN/Models/L10n.swift`, `MadFrogVPN/Resources/{en,ru}.lproj/Localizable.strings`,
`MadFrogVPN/Views/SupportChatView.swift`.
Next: finish **B5** (`AnnouncementView` cta/dismiss/badge localization), then **B7** (Google logo) /
**B15** (email placeholder + stale DE mock) — all `swiftc -parse`/`plutil`-verifiable.

### 2026-06-21 · Iteration 8 — finish B5 (announcements) + B15 (stale mocks/placeholder)
- **B5 (announcements):** `AnnouncementView` CTA fallback ("Открыть"), dismiss ("Понятно"), and the three kind
  badges ("🎁 АКЦИЯ" / "✨ ОБНОВЛЕНИЕ" / "ℹ︎ ВАЖНО") were hardcoded RU rendered via `Text(verbatim)`. Localized
  via `String(localized:)` + 5 new `announcement.*` keys (en/ru). Admin-authored `ctaLabel` kept verbatim
  (dynamic content). **B5 now fully closed.**
- **B15:** `EmailSignInView` prompt `Text("email")` → `Text(L10n.Magic.emailPlaceholder)` (the localized
  "you@example.com" already existed but was bypassed). `ThemePickerView` mock "DE-1 · 24ms" → "Netherlands ·
  24ms" (DE is retired; "DE-1" leaf-naming is what the home screen deliberately hides).
- **Verify:** `swiftc -parse` OK (AnnouncementView, EmailSignInView, ThemePickerView); `plutil -lint` OK;
  **en/ru key parity 296=296**; no residual RU literals in AnnouncementView. Rides CI build.
- **Minor left:** the theme-preview "Connected" label is still hardcoded English (illustrative mock chrome,
  P3); the stale `.string` doc-comment in L10n.swift.

Files: `MadFrogVPN/Views/{AnnouncementView,EmailSignInView,ThemePickerView}.swift`,
`MadFrogVPN/Resources/{en,ru}.lproj/Localizable.strings`.

— **9 commits, B-track substantially done** (B5/B6/B8-pending/B15 + A8). Remaining B items are heavier
(B1 paywall pitch, B2 onboarding, B4 proof-of-protection — real UI, higher review value) or asset-dependent
(B7 Google logo needs the official asset). Next: assess B-track remainder vs. winding the loop toward an
owner-review handoff (the highest-value remaining work — A2/A3 billing, A1 enable, on-device verification — is
owner-gated).

### 2026-06-21 · Iteration 9 — B1 paywall value-pitch (both paywalls)
The revenue moment was a bare price list. Added a shared `PaywallBenefits` block above the plans on BOTH the
StoreKit (`PaywallView`) and FreeKassa (`WebPaywallView`) paywalls.

- **What:** new `MadFrogVPN/Views/PaywallBenefits.swift` (5 themed bullets: no-logs, fast servers (NL/FR),
  unblock sites/apps/streaming, no ads/limits, and a highlighted **"no auto-renew — no surprise charges"**) +
  `L10n.PaywallBenefits` (5 keys, en/ru). Wired after the header in both paywall bodies.
- **Deliberate copy choice:** NO "3 days free" bullet — the paywall frequently shows AFTER the once-per-account
  trial is spent (connect-gate), so promising a trial there would be misleading. Instead the non-renewing model
  is reframed as a *trust* selling point ("no surprise charges"), which is accurate in every state.
- **Verify:** `swiftc -parse` OK (PaywallBenefits, PaywallView, WebPaywallView, L10n); `plutil -lint` OK;
  key parity **301=301**; all 5 benefit keys present in both langs. XcodeGen globs pick up the new view file.
  Rides CI build.
- **Remaining refinement:** a "best value" badge on the Apple `PlanCard` (web cards already show savings % from
  A8); restating the trial belongs in onboarding (B2/B3), not here.

Files: `MadFrogVPN/Views/{PaywallBenefits.swift,PaywallView.swift,WebPaywallView.swift}`,
`MadFrogVPN/Models/L10n.swift`, `MadFrogVPN/Resources/{en,ru}.lproj/Localizable.strings`.

— **10 commits.** B-track value items mostly done (A8 savings, B1 pitch, B5/B6/B15). The remaining B work is
heavier UI needing on-device review (B2 onboarding, B4 proof-of-protection, B9 account screen, B11 list
consistency) + asset-dependent (B7). Approaching the point where the highest-value next steps are owner-gated
(A2/A3 billing, A1 enable, on-device verification of this whole branch). Will keep doing safe verifiable items
and lengthen cadence as the safe backlog thins.

### 2026-06-21 · Iteration 10 — B8 Restore Purchases in Account (+ cadence note)
- **What:** added a "Restore Purchases" row to `AccountView` (was only on the paywall, so a reinstalled payer
  who never opened the paywall couldn't recover access → "I paid but it's gone" tickets). Calls
  `app.subscriptionManager.restorePurchases()` (StoreKit) **and** `app.refreshConfig()` (reclaims a
  cross-device FreeKassa payment too), then shows a result alert (restored / nothing found). Used
  `app.subscriptionManager` (AppState owns it, `private(set)`) rather than `@Environment(SubscriptionManager)`
  — the env isn't injected on the Account path, so this avoids a potential runtime crash.
- **Verify:** `swiftc -parse` OK (AccountView, L10n); `plutil -lint` OK; key parity **304=304**. Rides CI build.

— **10 commits.** This is the natural end of the autonomously-safe backlog: revenue groundwork (A1/A8/A9),
UX value + trust (B1/B5/B6/B8/B15), infra safety + debt (D1/D2/D7/D10/D11/D15/D17) are done or advanced. The
remaining registry items are owner-gated (A2/A3/A1-enable/on-device verify) or heavier UI that needs your
review (B2 onboarding, B4 proof-of-protection, B9 account redesign, B11 list consistency, C1 kill-switch).
Per stewardship, the loop now moves to a **long idle heartbeat** rather than manufacturing marginal commits —
it stays alive to pick up direction when you wake. Re-point it any time by replying to this session.

### 2026-06-21 · Iteration 11 — finishing touches (heartbeat tick)
Small zero-risk cleanups (no new risky work while idling):
- `ThemePickerView` theme-preview mock said hardcoded English "Connected" — now `L10n.Home.statusProtected`,
  so the preview matches the REAL home copy ("Protected"/"Защищены") and localizes.
- L10n.swift doc-comment referenced a `.string` accessor that was never implemented → corrected to point at
  `String(localized:)`.
- **Verify:** `swiftc -parse` OK (both). Rides CI build.

Files: `MadFrogVPN/Views/ThemePickerView.swift`, `MadFrogVPN/Models/L10n.swift`. Loop stays on hourly heartbeat.

### 2026-06-21 · Iteration 12 — REAL-DATA prod investigation (RU sign-in) + live monitor
Owner redirected: the real churn driver isn't the billing model — it's that **after paying, the VPN misbehaves
(drops itself, asks to re-login), and RU sign-in is flaky** — and he wants decisions driven by REAL prod data,
not the audit doc. So I went to the boxes (NL, MSK) and measured.

**What the data actually showed:**
1. **NL backend auth is HEALTHY** — 24h: 46×401, 28×403, 1×500, 8 refresh-reuse. Not mass failure. → the RU
   sign-in failures **never reach NL** (RKN RSTs them in flight), so server logs look clean while users can't
   log in. Confirms it's a *transport* problem, only visible from a RU vantage.
2. **Direct-IP auth fallback legs are DEAD BY DESIGN (new finding).** Ground truth on NL: `:443` is sing-box
   Reality presenting a `*.adfox.ru` (Yandex) cert; **there is no `api.madfrog.online` cert on NL**, API is on
   `:80` only. The app's direct-IP auth legs dial `IP:443` SNI=`api.madfrog.online` and verify chain-vs-SNI
   (`DirectConnection.swift:148`) → they get the Reality cert → **rejected**. And that SNI is RKN-filterable on
   any IP. So **RU sign-in transport = primary(CF) + clean-SNI decoy(→MSK) only**; the "direct-IP fallback" the
   team thought it had for auth contributes nothing in RU.
3. **The live App Store build (1.0.30) has NO decoy leg** (that's 1.0.33/TestFlight) → live RU users rely on
   **Cloudflare alone**; when CF throttles in residential RU, sign-in fails with zero fallback. This is the
   user's exact symptom, grounded in data.
4. From MSK (real RU IP) right now: `primary=200, decoy=200` — so the failures are **intermittent/residential**,
   not reproducible from a datacenter (why "проверим на устройстве" kept failing).
5. Minor: NL logs `sing-box check skipped: binary not found on PATH` every 10 min — the periodic engine-reload's
   config validation guardrail is silently off (binary isn't in the backend container). Latent VPN-outage risk.

**What I shipped (server-side, autonomous, verified live):**
- **RU-vantage auth monitor deployed to MSK** (`/opt/chameleon/monitoring/ru-auth-healthcheck.sh`, cron */5),
  reframed to the TRUE leg model: alerts when the decoy leg dies (the RKN-resilient survivor) or both legs die.
  Telegram alerting replicated from NL + **verified end-to-end** (test alert delivered). Turns "ship blind" into
  "know within 5 min when RU auth breaks." Honest limit: datacenter vantage misses residential-only throttle.

**Real-data-driven next steps (recorded, see registry `RU-AUTH-LEGS-DEAD`):**
- CRITICAL (owner): ship 1.0.33 → gives live RU users the decoy leg they currently lack.
- Client (next build): drop the dead direct-IP-SNI-api auth legs; add a SECOND clean-SNI decoy on SPB so RU
  sign-in isn't single-legged; add per-leg sign-in telemetry so residential failures become measurable from
  real devices (the only way to see the intermittent case).
- Server: fix the NL `sing-box check` guardrail; stand up a 2nd decoy on SPB (ready for the client leg).

Files: `infrastructure/monitoring/ru-auth-healthcheck.sh` (deployed to MSK).

### 2026-06-21 · Iteration 13 — kill the RU sign-in SPOF (2nd decoy leg) — server LIVE, client coded
Acting on the iter-12 finding (RU sign-in = CF + the single MSK decoy = SPOF). Added a SECOND clean-SNI decoy.

- **Server (DEPLOYED + verified live, zero VPN risk):** stood up a 2nd decoy on **SPB:8443** — a separate port
  that does NOT touch SPB's live VPN `:443` stream passthrough (verified intact: still presents NL Reality
  `*.adfox.ru` cert after reload). Copied the SAME pinned cert from MSK (fingerprint `497b4ff…` confirmed), added
  the vhost (`infrastructure/spb-relay/decoy-adfox.conf`), `ufw allow 8443`, `nginx -t` OK, graceful reload.
  **Tested from MSK (real RU IP): SPB:8443 decoy = 200 in 0.15s.** Real client IP preserved (direct TLS term,
  not behind the stream; NL already trusts SPB's XFF).
- **Client (coded, parse-verified, rides build):** `AppConfig.decoyRelays = [(MSK,443),(SPB,8443)]`; the
  `dataWithFallback` decoy branch now races BOTH relays. Same pin validates either. A relay not yet serving the
  decoy just pin-mismatches and drops out → the client leg was safe to write before/independent of the server.
- **Monitor (updated + redeployed to MSK):** probes both decoy relays; `decoy_ok` = either answers; new
  "🟠 redundancy degraded (one relay down, SPOF restored)" warn tier. Live run: `primary=200 decoy_msk=200
  decoy_spb=200`.
- **Verify:** `swiftc -parse` OK (Constants, APIClient); `bash -n` OK; live RU-vantage 200 on all three legs;
  VPN passthrough confirmed untouched.

Net: RU sign-in is no longer single-legged the moment the next build ships (server side is already live + the
client races it). Still owner-gated: ship a build carrying `decoyRelays` (1.0.33 line) so users get it.
Files: `Shared/Constants.swift`, `MadFrogVPN/Models/APIClient.swift`,
`infrastructure/monitoring/ru-auth-healthcheck.sh`, `infrastructure/spb-relay/decoy-adfox.conf`.

<!-- next iteration appended below -->
