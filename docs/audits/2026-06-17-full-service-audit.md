---
date: 2026-06-17
type: audit
scope: full-service (iOS, backend, nodes, admin, monetization, support-chat, auth)
method: 35-agent multi-agent audit (8 subsystem finders + adversarial P0/P1 verify + synthesis)
stats: 8 subsystems, 53 findings, 22 confirmed P0/P1
trigger: user pain (Instagram-not-loading, re-enter app, RU sign-in flapping, support-chat unclear) + real iPhone tunnel log
---

# Аудит MadFrog VPN — план работ

## 1. Резюме (что болит и почему)

Приложение зрелее, чем кажется по списку жалоб: бэкенд (auth/payments/IAP), StoreKit, support-chat DB-модель и admin-безопасность построены добротно. Боль пользователя — это **не один сломанный модуль, а отсутствие устойчивости на стыках**. Сквозная нить: когда RU→FR-транзит троттлится (а это происходит регулярно — incident 2026-06-06), у клиента **DNS резолвится только через выбранный exit без fallback** (clientconfig.go:505) → ничего не грузится (инста, боль #1); строгий country-pin **не имеет авто-failover** и единственный авто-recovery (`RealTrafficStallDetector`) задушен инфляцией порогов + мёртвым suppressor'ом (RealTrafficStallDetector.swift:77-96, addCloseEvent без вызовов) → туннель висит, юзер передёргивает приложение (боль #2). Интерактивный вход (Apple/Google/magic-verify) **не получил direct-IP fallback** из AUTH-RKN-DIRECT-IP — он остался primary-only через CF (APIClient.swift:584/626/695), плюс **rotated refresh-token не сохраняется** (force-релогин раз в ~сутки) → «вход то через РУ то нет» + постоянные релогины (боль #3, #2). Paywall-on-connect для истёкших — **чистая отсутствующая фича** на всех слоях (toggleVPN без проверки entitlement, сервер не выселяет истёкшие UUID между деплоями — утечка ревенью). Support-chat «в непонятном состоянии» — это **протухающий 10-мин SSE-токен, который не перевыпускается** (widget/index.html:295). Итог: ядро здоровое, но граничные сценарии РФ-сети рушат UX, и это бьёт по выручке.

## 2. Карта проблем по слоям

### iOS PacketTunnel / память / DNS / failover
| Sev | Проблема (anchor) | User impact | Effort |
|---|---|---|---|
| **P0** | DNS без fallback: dns-remote Proxy-only (clientconfig.go:505, :558) | Боль #1: exit троттлится → DNS дохнет → инста не грузится | M |
| **P0** | Нет reassert/restart после oom-killer "resetting network" (ExtensionPlatformInterface.swift:355) | Боль #2: каждые 5-6 мин рвутся коннекты, ничего не переподнимает | M |
| **P1** | RealTrafficStallDetector задушен: пороги 20/12/0.75/8, suppressor мёртв (RealTrafficStallDetector.swift:77-96, addCloseEvent без вызовов) | Боль #2: единственный авто-recovery почти не срабатывает | M |
| P2 | oom-killer @40MiB: GOMEMLIMIT=42MiB + мёртвый dns-fakeip + split-brain independent_cache (ExtensionProvider.swift:160/399; clientconfig.go:507/513) | Гигиена памяти, не доказанный root-cause | M |
| P2 | Country-pin: extension-recovery re-probит только "Auto", `setCountryGroupTags` — мёртвая проводка (TunnelStallProbe.swift:101/103) | Боль #1/#2 для pinned-country (by-design) | L |
| P2 | TunnelStallProbe качает 32КБ/15с впустую (build-44 passive) | Жрёт трафик+память в memory-starved extension | S |

### iOS login / RU sign-in / identity
| Sev | Проблема (anchor) | User impact | Effort |
|---|---|---|---|
| **P1** | Интерактивный вход без direct-IP fallback (APIClient.swift:584/626/695 — bare `session.data`) | Боль #3: первый вход в РФ падает без recovery | M |
| **P1** | Rotated refresh-token не сохраняется → детерминированный force-релогин ~раз в сутки (APIClient.swift:723-744; AppState.swift:773-785; backend rotации auth.go:460-516) | Боль #2: «постоянно надо перезаходить» | M |
| P2 | magic-link request/verify асимметрия (requestMagicLink:663 c fallback, verifyMagicLink:695 — primary-only) | Боль #3: письмо приходит, redeem падает | S |
| P3 | raceLegPlan RU-фильтр на pruned IP 162.19.242.30 — мёртвый код (APIClient.swift:149-154) | Маскирует отсутствие real RU-detection | S |
| P3 | sign-in юзает 4s-config session с 20s override — latent foot-gun | Латентный риск | S |

### iOS app quality / server-selection
| Sev | Проблема (anchor) | User impact | Effort |
|---|---|---|---|
| **P1** | Live country-pick молча сбрасывается в Auto (resolveSelectionChain vs chainOrFallback, AppState.swift:1867/1877-1880) | Боль #6: «выбор не запоминается» | M |
| P2 | Connect без gate на подписку — нельзя paywall'ить на connect (requestToggle AppState.swift:1250; toggleVPN:1291) | Боль #5 (фича) | M |
| P2 | SRV-DYNAMIC полу-готов: 3 хардкод-таблицы стран (ServerGroup.swift:75/288-298) | Новая страна = новый билд | M |
| P2 | Connect-watchdog ~37-40s > мандата 30s | Боль #2: спиннер 40с, юзер сдаётся | M |
| P3 | PathPicker задокументирован как primary, но обходится live-path | Боль #6: 2 модели «кто выбирает сервер» | S |
| P3 | reconnect-on-switch гонится с teardown без single-flight | Боль #2 (редкий тайминг) | M |

### Support chat
| Sev | Проблема (anchor) | User impact | Effort |
|---|---|---|---|
| **P1** | SSE chat-token (10мин TTL) не перевыпускается на reconnect (widget/index.html:286/295/416; jwt.go:159) | Боль #2/#4: чат молча умирает → надо перезаходить | S |
| P2 | Bearer-токен в webview не рефрешится in-page → 401 на длинных сессиях | Боль #4 | M |
| P2 | User-side B2 PUT cross-origin зависит от непроверенного CORS-allowlist | Боль #4: фото «иногда грузится» | M |
| P3 | Greeting — клиентский ephemeral bubble без id | Боль #4: пустой чат на 2-м устройстве | S |
| P3 | send-log fallback теряет лог молча, рапортует `.sent` | Боль #4: думаешь отправил лог, а ушёл только текст | S |
| P3 | readSingboxLogTail берёт last 256КБ — спам oom-killer вытесняет ошибку | Боль #1/#4 | M |
| P3 | Admin reply без optimistic echo, 3с polling | Латентность саппорта | M |

### Monetization / expired→paywall
| Sev | Проблема (anchor) | User impact | Effort |
|---|---|---|---|
| **P1** | toggleVPN() без проверки подписки — истёкшие коннектятся с кэша (AppState.swift:1291) | Боль #5: нет paywall в момент intent | S |
| **P1** | Сервер не выселяет истёкшие UUID между деплоями (ReloadVPNEngine только при `changed`, peers пустые; sync.go:196/109; deploy.sh:207) | Утечка ревенью/bandwidth | M |
| **P1** | Paywall достижим только через мелкий chip (9/257 показов; MainViewCalm.swift:330, Neon:120/416) | Структурно убитая воронка | S |
| P2 | fetchAndSaveConfig глотает 403 "subscription expired" (AppState.swift:488, нет 403-arm) | Stale config, неверный paywall-state | S |
| P2 | Home показывает истёкшего как «PRO» (`!= nil` вместо `> now`) | Боль #5/#6 | S |
| P2 | WebPaywall без promo-поля (PROMO Phase B) | Win-back кампания невозможна | M |
| P3 | StoreKit loadProducts без авто-retry на empty | Тихая потеря конверсии non-CIS | S |

### Backend (Go)
| Sev | Проблема (anchor) | User impact | Effort |
|---|---|---|---|
| **P1** | Refund → subscription_expiry=NULL проходит /config gate (credit.go:260; config.go:59/259) | Полностью возвращённый юзер сохраняет VPN | S |
| **P1** | Relay source-IP схлопывает всех RU в один 60/min bucket (nginx.conf XFF отсутствует; SPB L4) | Боль #3: первый юзер на relay лочит остальных | M |
| P2 | Expired-connect не триггерит paywall — 403 без machine-readable code (config.go:59-61) | Боль #5: клиент вынужден string-match | S |
| P2 | Apple ASN-credit для unknown originalTransactionId молча дропается | «Я оплатил, а пишет expired» | M |
| P2 | FreeKassa webhook доверяет client-influenced amount | Latent abuse при promo-баге | M |
| P2 | Support send-log 3-step presign→PUT→send с silent degradation | Боль #4 | M |
| P2 | GetConfigLegacy /sub/:token — credential-in-URL | Standing leak (если route жив) | S |
| P3 | captureInitialContext/touchDevice — unbounded goroutines | Усиливает инциденты при reconnect-storm | S |

### Nodes / infra / observability
| Sev | Проблема (anchor) | User impact | Effort |
|---|---|---|---|
| **P1** | Нет health-gating exit'ов — троттленный GRA в каждом конфиге (servers.go:135-148; relay.go:218) | Боль #1/#2: degraded exit не отзывается | M |
| **P1** | Нет внешнего synthetic VLESS-монитора (MON-01/07); Prometheus на самом NL | Боль #1/#2: все инциденты находят юзеры | M |
| **P1** | NL — SPoF (backend+DB+exit); NL-RED-01 не начат (project.yaml:70; deploy.sh:209) | Любой сбой NL = тотальный outage | L |
| P2 | Proxied DNS без fallback (дубль iOS-P0, clientconfig.go:505) | Боль #1 (P0 в iOS-разрезе) | M |
| P2 | UDP-leg health = fake-green QUIC-handshake (PROTO-01) | Escape-hatch выглядит живым, но мёртв | M |
| P2 | Relay-конфиги правятся на боксах, MSK nginx не в репо | DR-gap: reinstall стирает fix флапа | S |
| P3 | Pinned-country без cross-country failover (уже есть toast, clientconfig.go:365-388) | Боль #1 (mitigated, нужен actionable toast) | M |

### Admin SPA / ops
| Sev | Проблема (anchor) | User impact | Effort |
|---|---|---|---|
| P2 | Нет user-detail страницы (USR-05): backend GetUser есть (routes.go:137), SPA-route нет (App.tsx:202-208) | Боль #1/#2/#3/#4: триаж = ручной кросс-реф | M |
| P2 | Status слеп к France/GRA (status.go:73-102; есть на Nodes page) | Боль #1: троттл FR = all-green | M |
| P2 | Support inbox без user-context (support.go:43-54) | Боль #4: ответы дженерик | M |
| P2 | vpn.connect.fail без exit-country (AppState.swift:1396/1435/1444/1452) | Боль #1: нельзя атрибутировать FR | S |
| P2 | Нет login-failure ops-surface | Боль #3 неизмерима | M |
| P2 | Dashboard "Online" NL-only — недосчёт France | Неверная realtime-метрика | M |
| P3 | Per-page polling fan-out без backoff | Нагрузка на SPoF NL | M |

---

## 3. План работ по фазам

### Фаза 0 — Болит прямо сейчас (P0)

**0.1 — DNS fallback для proxied-доменов** *(server-deploy, без билда)* · **M**
- **Anchor:** `backend/internal/vpn/clientconfig.go:505` (dns-remote `{1.1.1.1, Detour:"Proxy"}`), `:558-561` (DefaultDomainResolver).
- **Fix:** добавить второй DNS-сервер без detour (например dns-direct/второй DoH) и route-level dns-rule, чтобы sing-box падал на direct-резолв по таймауту, когда Proxy-резолв висит. По умолчанию Proxy=selector→Auto (urltest, 10с), значит для Auto-юзеров основной кейс уже следует за живым leg'ом — но при «все legs degraded» резолв всё равно зависает; fallback закрывает это окно. Принять минимальный RU-geo-leak только на fallback-ветке.
- **Test:** `sing-box check -c config.json` на сервере + on-device: запинить FR при деградированном FR-транзите, проверить что инста резолвится. Регрессия против захваченного 626-timeout лога.

**0.2 — Self-heal после oom-killer "resetting network"** *(app build)* · **M**
- **Anchor:** `RealTrafficStallDetector` уже парсит лог-строки (`ExtensionPlatformInterface.swift:355`); self-heal через `reloadService(config)` (`ExtensionProvider.swift:459`).
- **Fix:** fast-path матч `'resetting network'` / `'memory pressure: critical'`; при N срабатываний в окне → re-apply routing mode + `nudgeNow()` или `reloadService`. Маркер в TunnelFileLogger для подтверждения в полевых логах.
- **Test:** unit на парсер-матчер; интеграционно — инжект синтетических лог-строк, проверить вызов self-heal.

> **Примечание по severity:** Verify-агенты понизили чисто-iOS «DNS P0» и «oom P0» как отдельные находки (Proxied-DNS реально P2 в default Auto-пути; oom-memory — P2-гигиена). Но **связка DNS-fallback + self-heal остаётся приоритетом №1 по felt-pain**, поэтому держим их в Фазе 0. Память (GOMEMLIMIT bump до 46-48MiB, удалить мёртвый dns-fakeip clientconfig.go:507, согласовать independent_cache) делаем как **сопутствующую M-задачу с обязательным полевым замером memoryWatchdog до/после** — не вслепую.

**0.3 — Direct-IP fallback для интерактивного входа** *(app build)* · **M**
- **Anchor:** `APIClient.swift:584` (signInWithApple), `:626` (signInWithGoogle), `:695` (verifyMagicLink) — все `bare session.data`.
- **Fix:** маршрутизировать через `dataWithFallback(sensitive:true)` (cert-validated direct-IP legs MITM-safe per H-002b). **Обязательно сначала** сузить winner-rule в `dataWithFallback`: leg выигрывает только на 2xx ИЛИ 401 (сейчас выигрывает любой `<500`, см. :345/:404) — иначе вернётся build-53 регрессия «transport-mangled 4xx тенью накрывает primary 200». Добавить 1 retry на network-error (как fetchAndSaveConfig:535). Этим же фиксом закрывается P2 magic-verify асимметрия (:695).
- **Test:** unit на winner-selection (2xx/401 only); on-device вход из РФ при throttled CF.

**0.4 — Сохранять rotated refresh-token + expires_at** *(app build)* — спавнен как task_cf453dc4 · **M**
- **Anchor:** `APIClient.refreshAccessToken:723-744` (читает только `access_token`), `AppState.tryRefreshToken:773-785` (не пишет `configStore.refreshToken`). Бэкенд ротирует single-use refresh (`auth.go:460-516`, reuse→401), и уже отдаёт `expires_at` (jwt.go:41,109; auth.go:50,185,…) — клиент его выбрасывает.
- **Fix:** парсить и сохранять новый `refresh_token` + `expires_at`; в `initialize()` проактивно рефрешить при подходе к expiry перед первым authed-вызовом. Это устраняет детерминированный force-релогин ~раз в 24-48ч (главный драйвер боли #2).
- **Test:** unit — второй refresh использует НОВЫЙ токен; интеграционно — двойной refresh не даёт 401.

### Фаза 1 — Фичи и костыли (P1)

**1.1 — Expired → paywall-on-connect (фича, боль #5)** — полный дизайн через 3 слоя:

*Клиент* *(app build)* · **S**
- `AppState.swift:1250` requestToggle: на connect-ветке (`!isConnected`) проверить `let active = subscriptionManager.isPremium || (subscriptionExpire.map { $0 > Date() } ?? false)`. **Важно:** также блокировать когда `subscriptionExpire == nil` при наличии кэш-конфига (nil ставится для lapsed/never-sub, AppState.swift:1151/1214 — иначе nil проскочит guard). Если `!active` → новый `@Published showPaywallRequested`, сначала `await refreshConfig()` (реклейм юзера, оплатившего на другом устройстве), затем paywall-sheet через существующий `PaywallRouter` (MainView.swift:125). Disconnect всегда разрешён.
- `fetchAndSaveConfig` (AppState.swift:488): добавить `catch APIError.serverError(403)` рядом с 404-arm — не чистить creds/config, выставить `subscriptionExpired=true`.
- Исправить home-label: `subscriptionExpire != nil` → computed `isSubscriptionActive` (логика уже в subActive:310) во всех местах (MainViewCalm:75/333, Neon:118/442-447).

*Бэкенд* *(server-deploy)* · **S** — `config.go:59-61`: добавить machine-readable `{"code":"SUBSCRIPTION_EXPIRED","expired_at":...}` + всегда слать `X-Expire` даже на 403, чтобы клиент не string-match'ил.

*Бэкенд — закрыть утечку* *(server-deploy)* · **M** — `sync.go`: вызывать `s.reloadVPN(ctx)` в reconcileLoop каждые N тиков **независимо от `changed`**, ИЛИ отдельная expiry-sweep goroutine в `cmd/chameleon`, дёргающая `ReloadVPNEngine` по таймеру (peers пустые → loop сейчас вообще не стартует, sync.go:109). Это реоткрывает P0-E fraud-path.
- **Test:** unit на gating-предикат (включая nil-кейс); backend test — `/config` 403 после refund sole-charge; на NL — проверить выселение тестового UUID после прохождения expiry.

**1.2 — Refund-leak: NULL expiry проходит gate** *(server-deploy)* · **S**
- **Anchor:** `credit.go:260-262` (`subscription_expiry=NULL`, is_active не трогается), `config.go:59`/`:259` (NULL пропускает gate).
- **Fix:** в `setStatusAndReconcile` при `newExpiry==nil` ставить `is_active=false` (guard'нуть на refund/former-payer кейс, чтобы не загейтить trial/pre-pay где is_active=true+expiry=NULL by design). **Не** менять `config.go` на `==nil` напрямую.
- **Test:** `credit_refund_test.go` — `/config` 403 после refund единственного charge.

**1.3 — Support-chat: live-stream не умирает (боль #4/#2)** *(в основном webview, перезалить bundled widget → app build)* · **S**
- **Anchor:** `clients/widget/index.html:286` openStream (вызывается 1 раз :416), `:295` onerror только `setConn('connecting')`; токен запечён в EventSource URL, TTL 10мин (jwt.go:159).
- **Fix:** на `sse.onerror` закрывать EventSource и планировать debounced `openStream()` (с re-fetch `/support/chat-token`) с backoff, вместо встроенного retry на протухший URL. Доп. re-open на `visibilitychange→visible`. Этой же проводкой решается P2 «Bearer не рефрешится in-page» (window.refreshToken() / postMessage→native re-mint).
- **Test:** держать чат >10мин, форсить reconnect, проверить что приходят agent-reply без перезахода в приложение.

**1.4 — Live country-selection не сбрасывается в Auto (боль #6)** *(app build)* · **M**
- **Anchor:** `AppState.swift:1867` resolveSelectionChain (строгий), деструктивный reset `:1877-1880`.
- **Fix:** `applyServerSelectionIfLive` использовать тот же forgiving `chainOrFallback(target:)`, что и persistence; **убрать** обнуление persisted-selection при нерезолве — оставить pin, залогировать, дать следующему config-refresh примирить.
- **Test:** unit — flat (urltest-less) Proxy-конфиг, pin переживает.

**1.5 — Send-log не теряет лог молча (боль #4)** *(клиент+сервер)* · **S/M**
- **Anchor:** клиент — fallback рапортует `.sent`; бэкенд — `SupportSend` принимает key без HEAD-проверки B2.
- **Fix:** клиент — третий кейс `.sentWithoutLog` + мягкий тост, не давать success-haptic когда лог не приложился. Бэкенд — HEAD B2-объекта перед приёмом key (400 если нет), типизированный `attachments_unavailable` при Storage==nil. Проверить B2 CORS-allowlist для user-side PUT (или проксировать через бэкенд — same-origin).
- **Test:** симуляция failed-PUT → корректный degraded-статус и у юзера, и у агента.

### Фаза 2 — Надёжность / инфра (P1/P2)

**2.1 — Health-gating exit'ов** *(server-deploy)* · **M**
- **Anchor:** `servers.go:135-148` (gate только `is_active`), `relay.go:218` (push-failure только Warn+continue).
- **Fix:** колонка `vpn_servers.last_healthy_at`; backend-probe (TCP+through-tunnel HTTP, reuse urltest-target) на exit каждые ~30-60с; `ListActive*` исключает exit'ы старше N мин (с floor, чтобы не опустошить список). Пара с 2.2.
- **Test:** уронить FR-транзит на стенде → GRA исчезает из конфига в пределах N мин, не опустошая список.

**2.2 — Внешний synthetic VLESS-монитор (MON-01/07)** *(внешний хост, не Timeweb)* · **M**
- **Anchor:** MON-01/07 в roadmap.yaml#next.monitoring (unbuilt); health-check.sh:98 — listen-only `ss`, не handshake; Prometheus на самом NL.
- **Fix:** маленький внешний бокс (RU-relay / fly.io / GH-Actions cron) с headless sing-box на prod-клиент-конфиге, curl `gstatic/generate_204` через каждый exit-leg каждые 15мин via Clash API, алерт в Telegram (reuse telegram-alert.sh). + 1-строчный UptimeRobot на api.madfrog.online (MON-01).
- **Test:** заблокировать exit → алерт в Telegram < 15мин.

**2.3 — Relay-конфиги в репо (DR-gap)** *(repo + sync)* · **S**
- **Fix:** ре-синк живого SPB conf в `infrastructure/spb-relay/` (дрифт: connect_timeout 5→15с, max_fails=0); добавить `infrastructure/msk-relay/` с живым nginx (api front + SSE location + stream chains) + README sync-flow; diff-скрипт live↔repo.

**2.4 — RU rate-limit bucket (боль #3, бэкенд-причина)** *(server-deploy)* · **M**
- **Anchor:** nginx XFF отсутствует на MSK; SPB — L4 stream.
- **Fix:** (a) на MSK nginx — `set_real_ip_from`+`real_ip_header XFF` (как на NL nginx.conf:42-52); для SPB L4 — PROXY protocol (`proxy_protocol on` на stream listen + `listen 8000 proxy_protocol` на NL + `set_real_ip_from 185.218.0.43`). (b) в коде — exempt relay-IP из per-IP лимитера / switch auth-routes на per-user key, поднять burst для /auth/*.
- **Test:** load-test из-за relay — несколько юзеров не лочат друг друга.

**2.5 — NL SPoF (NL-RED-01)** *(infra)* · **L**
- **Fix:** Hetzner Helsinki standby по acceptance NL-RED-01 (handshake из RU-carriers), Postgres streaming replication + документированный manual failover (DNS A-swap api.madfrog.online на MSK). Сначала закрыть INFRA-SYNC-01 (payments/id_aliases replication, deploy.sh:204). Трекать в decision 0004. *(Высокий blast-radius, низкая частота — планировать, не блокировать.)*

### Фаза 3 — Монетизация и долги (P2/P3)

- **3.1 Воронка paywall** *(app build, S):* триггер `PaywallRouter` на trial-expiry transition при launch + one-time post-onboarding; инструментировать `paywall.route`/`paywall.view`. Замерить lift против 9/257.
- **3.2 WebPaywall promo-поле (PROMO Phase B)** *(app build, M):* TextField + `validatePromo` → `/payment/promo/validate`, для win-back кампании.
- **3.3 Admin user-detail (USR-05)** *(SPA, M):* route `/users/$id` в App.tsx, link username-cell (pages/users.tsx:236); расширить `toUserResponse` (payments/events/support-thread). Бэкенд GetUser уже есть (routes.go:137). Свернёт 4 ручных lookup'а в один — ускорит триаж всех болей.
- **3.4 Observability болей** *(S каждый):* vpn.connect.fail + exit-country (AppState.swift:1396/1435/1444/1452); enrich support-inbox DTO (LEFT JOIN users уже есть, support.go:242-287); login-failure событие в app_events; Status-probe France (но честно: NL→FR probe не ловит RU→FR throttle — value ограничен).
- **3.5 Apple ASN unknown-txn** *(server, M):* не ack-and-drop — вернуть 500 для retry ИЛИ persist в `apple_pending_notifications` и replay при /verify.
- **3.6 Долги/рефакторы** *(P3):* удалить dead-код (raceLegPlan RU-фильтр APIClient.swift:149-154; PathPicker framing; TunnelStallProbe 32КБ-loop); SRV-DYNAMIC до конца (cc-prefix вместо хардкод-таблиц ServerGroup.swift:75/288-298); GetConfigLegacy /sub/:token — проверить access-логи и удалить если мёртв; bound goroutines (touchDevice Redis-throttle 60с); FreeKassa amount re-derive; StoreKit loadProducts авто-retry; connect-watchdog 37-40s→<30s.

---

## 4. Что сделать ПЕРВЫМ (топ-5 на эту неделю)

1. **DNS-fallback (0.1, server-deploy)** — единственное изменение, мгновенно лечащее «инста не грузит» (боль #1) без билда и App-review; деплоится в тот же день.
2. **Direct-IP fallback для входа + 2xx/401 winner-rule (0.3, app build)** — прямая причина «вход то через РУ то нет» (боль #3); winner-rule обязателен первым, чтобы не вернуть build-53 reject.
3. **Сохранять rotated refresh-token (0.4, app build)** — устраняет детерминированный force-релогин ~раз в сутки, главный измеримый драйвер «постоянно перезахожу» (боль #2).
4. **SSE chat-token re-mint (1.3, widget)** — дёшево (S) и убирает «чат в непонятном состоянии» + ещё один повод перезаходить (боли #4/#2).
5. **Expired→paywall-on-connect + выселение истёкших UUID (1.1, клиент+сервер)** — единственная явно запрошенная фича (боль #5) и одновременно затыкает реальную утечку выручки на сервере.

> Связка self-heal после oom (0.2) и health-gating exit'ов (2.1) — следующие по felt-pain, но требуют app-build/полевого замера, поэтому идут сразу за топ-5.

Anchors взяты из подтверждённых verifyNote'ов дослье. Ключевые файлы: `backend/internal/vpn/clientconfig.go`, `clients/apple/MadFrogVPN/Models/APIClient.swift`, `AppState.swift`, `clients/apple/PacketTunnel/{ExtensionProvider,ExtensionPlatformInterface}.swift`, `clients/apple/MadFrogVPN/Models/RealTrafficStallDetector.swift`, `clients/widget/index.html`, `backend/internal/payments/credit.go`, `backend/internal/api/mobile/config.go`, `backend/internal/cluster/sync.go`, `backend/internal/db/servers.go`.