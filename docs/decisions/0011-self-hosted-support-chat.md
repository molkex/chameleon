---
title: "0011 — Self-hosted support chat (build on own stack, not Chatwoot)"
date: 2026-06-02
status: active
tags: [decision, support, chat, adr]
---
# 0011 — Self-hosted support chat (build on own stack, not Chatwoot)

- Status: accepted
- Date: 2026-06-02
- Supersedes: the Chatwoot-lean recorded in `roadmap.yaml#next.support.SUPPORT-CHAT`
  (`decision:` block) — that lean is now retracted in favor of building on our own stack.

## Context

The user wants an **in-app "messages with support"** chat, re-requested 2026-05-31, and
flagged that it must serve **multiple platforms**: iOS + macOS (native Swift, exist today)
plus Android and Windows (future) and the web landing.

The prior roadmap entry leaned toward **Chatwoot self-hosted**. Re-evaluated against the
multi-platform requirement and a resourcing concern (Chatwoot is Rails + PG + Redis +
Sidekiq, needs 2–4 GB RAM; NL is the sole backend/DB node and already ~1.9 GB / swapping —
decision 0004). Surveyed the OSS field: Chatwoot is the most feature-complete *omnichannel*
option but the heaviest; lighter alternatives each have a disqualifying catch (Papercups =
maintenance-mode/abandoned since 2025; FreeScout = live-chat is a paid module, email-first;
Zammad = heavier, needs Elasticsearch; Chaskiq = Rails, same weight; Live Helper Chat /
GoFly = lighter but thinner/niche).

The decisive factor is the **4-platform multiplier**: any "native chat screen per platform"
approach is written and maintained 4×. A single hosted web chat widget embedded via a webview
is written **once** and ships everywhere, and a brand-new platform picks it up for free.

## Decision

**Build the support chat on our existing stack** (Go 1.25 + Echo + pgx/Postgres + go-redis +
the React admin SPA + APNs-to-be), **not** Chatwoot or any external SaaS.

1. **Transport / realtime:** **SSE** (Server-Sent Events) for server→client live updates +
   **Redis pub/sub** fan-out. Client sends messages via plain authenticated `POST`. SSE chosen
   over WebSocket (no new dep, native `URLSession`/`EventSource` support, simpler retry) and
   over long-poll (latency, connection waste).
2. **Cross-platform delivery — write once:** a single hosted web chat widget at
   `chat.madfrog.online`, embedded per platform via a webview (`WKWebView` on iOS/macOS,
   `WebView` on Android, `WebView2` on Windows, `<script>`/iframe on the landing). The chat
   UI, SSE/reconnect logic, message rendering, and theming live in **one** web codebase.
   **Not a one-way door:** the backend REST + SSE contract is identical, so a specific
   platform can later get a native screen against the same API if its webview UX proves weak.
3. **Agent side:** a new **inbox page in the admin SPA** (`clients/admin/src/pages/inbox.tsx`),
   with its own SSE stream + Redis fan-out, sidebar unread badge, canned replies, internal
   notes, assignment, and a link into the existing rich user-detail view.
4. **Omnichannel-lite:** keep the existing `@MadFrogRobot` Telegram bot (separate repo on MSK)
   and wire it as an **inbound channel** into the same inbox via a thin HMAC-authed contract
   (`POST /api/v1/admin/support/inbound` in; outbound callback to the bot out). `users.telegram_id`
   already exists for user resolution.
5. **Auth into the webview:** a **short-lived (~5 min) chat token** minted by a new endpoint
   from the user's existing JWT, injected into the webview via the JS bridge — never the
   long-lived 24 h access token in a URL.

## Consequences — what this requires (none of it exists yet)

- **SSE is greenfield.** No SSE/WebSocket handler exists today; Redis pub/sub exists but only
  for cluster user-sync (`internal/cluster/pubsub.go`). Reusable pattern, new transport.
- **SSE infra gotchas (all must be fixed before SSE works in prod):**
  - `http.Server.WriteTimeout: 30s` (`cmd/chameleon/main.go:~370`) **kills the stream after
    30 s** → set to `0`, keep `ReadHeaderTimeout`.
  - Echo global `ContextTimeoutWithConfig{30s}` (`internal/api/server.go:~152`) cancels the
    request context → the SSE route must register **outside** that middleware.
  - nginx `proxy_read_timeout 30s` + default `proxy_buffering on` at **NL, SPB, and MSK**
    relays → add an SSE `location` with `proxy_buffering off`, long read/send timeouts,
    `proxy_http_version 1.1`. The Go handler also emits `X-Accel-Buffering: no`.
  - **MSK relay nginx config is not in the repo** — must be fetched/edited/re-applied on
    `217.198.5.52`. This is a deploy blocker for SSE over `api.madfrog.online`.
  - Route SSE only via **`api.madfrog.online` (MSK → NL), bypassing Cloudflare** — CF
    free/pro buffers SSE.
  - `EventSource`/`URLSession` SSE cannot set headers → the SSE endpoint accepts the chat
    token as a **query param**.
- **APNs push-to-device does not exist** (verified, backend + iOS). Standing it up needs: a
  **new APNs `.p8` auth key** in the Apple portal (distinct from the ASC key
  `AuthKey_6HX3DA4P2Y.p8` — Apple does not allow one key for both), `aps-environment`
  entitlement on `com.madfrog.vpn` + `com.madfrog.vpn.mac`, an HTTP/2 sender in Go, a unified
  `device_push_tokens` table, a registration endpoint, and `registerForRemoteNotifications`
  on the client. ~3 dev-days on top of the chat itself.
- **Schema:** migration `019` = `support_threads` + `support_messages` (with `channel`,
  `external_id`, `assigned_admin_id`, `is_internal`, `ON DELETE CASCADE`); migration `020` =
  `device_push_tokens` (one row per user+platform+token). `db.WipeUserOnDelete` (soft-delete)
  **must be extended** to hard-delete chat threads + push tokens (cascade won't fire on a soft
  delete).
- **Privacy policy conflict (App Store risk).** `legal.privacy.body` currently states we do
  **not** store "metadata tied to your usage." Stored chat messages contradict that. Must add
  a "Support chat" section + update the ASC privacy nutrition label (User ID / Customer
  Support / App functionality) **before** the next submission, or risk Guideline 5.1.1.
- **Rate limiting / abuse:** message send must be **user-id-keyed** (relays make all RU users
  share an IP), reusing the idempotency middleware to dedupe hedged sends.

## Alternatives considered (rejected)

- **Chatwoot self-hosted** — most features, but 2–4 GB VPS + ops, and a webview-embedded
  third-party widget in a privacy VPN; the multi-platform leverage is the same web-widget
  leverage we get building our own, without the resource cost or external surface.
- **Lighter OSS products** (Papercups / FreeScout / Live Helper Chat / Tiledesk / GoFly) —
  each disqualified (abandoned / paid live-chat / thinner / own infra anyway).
- **Native chat per platform** — best UX, but written and maintained 4×; rejected for a small
  team. Kept as a per-platform *upgrade* path on the same backend.
- **Telegram deep-link only** — cheapest, but not in-app and no unified inbox; kept only as
  the pre-launch interim.

## Open decisions (owed by the user, tracked in roadmap)

1. **Android & Windows stack** (Kotlin/Compose? Flutter? Electron? WinUI3?) — determines the
   webview host + push provider; future, does not block the iOS/macOS MVP.
2. **Is APNs push in the first ship**, or does the MVP launch foreground-only (SSE) with push
   as a fast-follow?
3. **Anonymous (no-auth trial) users** — allowed to chat (with tighter rate limits) or gated?
4. **Message retention policy** (e.g. hard-delete 90 days after thread close) — privacy-brand
   consideration.
