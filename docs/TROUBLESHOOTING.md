# Chameleon VPN — Troubleshooting

## ⚠ 2026-05-28: USR-09 Phase 2 — App Privacy disclosure MUST be updated before next iOS build submit

### Why
v1.0.27 (build 89) is currently WAITING_FOR_REVIEW. The **next** build (90+) will be the first to ship the `EventTracker`-based client-side event collection added in USR-09 Phase 2 (paywall views, product taps, purchase outcomes, vpn-connect failures, app lifecycle).

The App Store Connect "App Privacy" section currently lists ONLY the existing disclosures (device identifier + crash data). If a build that collects `paywall.product.tap` / `vpn.connect.fail` reaches review without updating App Privacy first, Apple rejects under Guideline 5.1.1 — "the data your app collects does not match what you declared".

### Pre-submit checklist (ASC UI → App Privacy → Data Types)
Add the following before clicking Submit on the build that includes `clients/apple/MadFrogVPN/Models/EventTracker.swift`:

1. **Product Interaction**
   - Linked to user: **Yes** (we have user_id)
   - Used for tracking: **No** (first-party analytics only; we do not share IDFA or device IDs with third parties)
   - Purpose: **Analytics** + **Product Personalization**
   - Reason in declaration: "Funnel analysis for in-app subscription paywall. Events: paywall view, product tap."

2. **Other Usage Data**
   - Linked to user: **Yes**
   - Used for tracking: **No**
   - Purpose: **Analytics** + **App Functionality**
   - Reason: "Diagnostics for VPN connection failures and app lifecycle events to surface incidents in our admin console."

### Where the data flows
- Client: `EventTracker` actor in main app process, persisted JSON in Application Support, drained over HTTPS to `POST /api/v1/mobile/events/batch` (JWT-gated).
- Server: `app_events` table on the NL backend node (Timeweb DE peer is dormant). 90-day retention informally; no off-host export. Schema in `backend/migrations/017_app_events.sql`.

### Verify the next build before submitting
- Run app once in TestFlight, open paywall, force-quit, reopen — `SELECT count(*) FROM app_events WHERE user_id = ?` on NL should show ≥ 3 events.
- Check `/admin/app/events` page renders rows with the test user's user_id.

### If you forget and get a 5.1.1 rejection
Apple sends a Resolution Center message naming the missing data type. Update App Privacy, **then** reply to the rejection — there's no need to resubmit a new build, the metadata is re-reviewed in-place. Lead time 1-3 days extra.

---

## 2026-05-27: Chameleon в restart-loop — `reality_private_key` wiped (MED-015)

### Симптом
NL chameleon container `Restarting (1)`, /health возвращает 000, новые юзеры не могут /auth/register или /api/v1/mobile/config. Singbox продолжает работать (свой config файл, не зависит от backend) — активные VPN-сессии не падают.

```
fatal: reality private key not found — set it in vpn_servers DB table or REALITY_PRIVATE_KEY env var
```

`vpn_servers.reality_private_key` для локальной ноды (`key='nl2'`) пустой (`length(reality_private_key) = 0`).

### Причина
**Admin SPA `PUT /api/v1/admin/servers/:id`** (вкладка "Servers" в админке) отправляет всё содержимое формы при сохранении. Форма НЕ показывает `reality_private_key` (это sensitive, должен быть за re-auth), поэтому в payload `reality_private_key = ""`. `db.UpdateServer` делал `SET reality_private_key = $10` без NULLIF guard, и пустая строка **затирала** существующий ключ.

В `admin_audit_log`:
```
15 | 2026-05-27 19:40:06 | server.update | 72.56.108.130 | id=93 key=nl2 host=147.45.252.234 port=443 active=true
```

При следующем перезапуске chameleon (любой `deploy.sh` или container restart) startup читает `vpn_servers` → priv = "" → fatal.

### Решение
1. **Recovery (immediate):** вытащить ключ из работающего `singbox-config.json` + `UPDATE vpn_servers SET reality_private_key=... WHERE key='nl2'`. Singbox volume mount → /etc/singbox/singbox-config.json содержит `inbounds[].tls.reality.private_key`.
2. **Prevention (MED-015):** `internal/db/servers.go` UpdateServer обернул `reality_public_key`, `reality_private_key`, `provider_password` в `COALESCE(NULLIF($N, ''), <column>)` — пустой payload-string preserve'ит сохранённое значение. Mirrors guard уже стоявший в `UpsertServerByKey`. Regression test `TestUpdateServerPreservesSecrets` пинит.

### Грабли
- **Не ротировать как fix.** Если делать rotation key пара когда backend в restart-loop, новый pub_key не доходит до клиентов (/config API down) → они продолжат handshake'ать со старым pub_key → silent auth fail. Сначала restore, потом если нужно — rotate с живым API.
- **Singbox + chameleon хранят private_key отдельно.** Singbox config файл — single source operational; DB — copy для chameleon. Cluster sync специально НЕ передаёт private_key между peers (см. `cluster/models.go SyncServer`). Bug сидел в одном-единственном UPDATE handler.
- **Sensitive fields в формах admin** — если не показываем (за re-auth), не отправляй пустой строкой. Лучший паттерн: не включать поле в payload вообще (omitempty) ИЛИ серверный guard как сейчас.

### Verify
```sql
SELECT key, length(reality_private_key) AS priv_len, length(reality_public_key) AS pub_len, updated_at
  FROM vpn_servers WHERE is_active = true;
```
Все priv_len должны быть > 0 (для VLESS Reality keypair ровно 43, base64url).

## 2026-05-27: Все юзеры с last_ip = MSK relay IP, last_country пустой

### Симптом
В админке у всех 78 юзеров `last_ip=217.198.5.52` (= MSK relay), `last_country=""`. Невозможно отличить юзеров по гео или real client IP для саппорта.

### Причина
1. **Real IP:** iOS race: при CF-throttling RU юзеры дополнительно ходят через `api.madfrog.online` (DNS-only → 217.198.5.52 MSK relay → NL). SPB relay forward'ил `X-Forwarded-For: client_ip`, но NL nginx не доверял SPB IP (`set_real_ip_from` только CF ranges + `127.0.0.1`), а коммит `b7f09c2` дополнительно жёстко перетёр `X-Forwarded-For` на `$remote_addr` = MSK IP. Echo `c.RealIP()` возвращал 217.198.5.52 для всех.
2. **Country:** ip-api.com был отключён на hot-path 2026-04-14 (Apple privacy). Initial_country пишется один раз на `/auth/register` — у юзеров зарегистрированных через MSK путь геолокация делалась по MSK IP, итог: пустота или Россия для всех.

### Решение (USR-01 + USR-02, commits `3709501`, `cea665b`)
1. `backend/nginx.conf`: добавлены MSK (217.198.5.52) и SPB (185.218.0.43) в `set_real_ip_from`; `real_ip_header` переключён с `CF-Connecting-IP` на `X-Forwarded-For` чтобы единый header работал и для CF (madfrog.online), и для SPB relay (api.madfrog.online). `recursive on` сохранён.
2. `internal/api/mobile/config.go touchDevice()`: country читается из `CF-IPCountry` header — free, no external API, no privacy disclosure. ip-api.com продолжает работать ТОЛЬКО на `/auth/register`. SPB-relay path не получает CF-IPCountry — last_country остаётся прежним (CASE-WHEN-empty guard в `TouchUserDevice` сохраняет старое значение).

### Грабли
- **`real_ip_header X-Forwarded-For` ВМЕСТО `CF-Connecting-IP`** работает потому что мы доверяем только known proxies (CF ranges + SPB IPs) в `set_real_ip_from`. Атакер с непосредственным connection IP не в trusted set → real_ip header игнорируется. См. nginx docs про recursive=on.
- **Existing 78 rows с last_ip=217.198.5.52** ничего не fixим — на следующем `/config` fetch организм перепишет на реальный IP. last_country same.
- **CF-IPCountry sentinels:** "XX" (non-country IP) и "T1" (Tor exit) — оба считаем пустыми, см. `cfCountryCode()` + `cf_country_test.go`.

### Verify
```bash
# Должно показывать real residential IPs, не 217.198.5.52
ssh root@147.45.252.234 'docker logs --tail 30 chameleon | grep -E "\"ip\":\"[0-9]" | head -5'
```

## 2026-05-25: DE окончательно отключён (OVH retired, не продлевался)

### Состояние
`162.19.242.30` — ping 100% packet loss, все TCP-порты timeout, SSH dead. OVH договор истёк, не продлевался.

### Cleanup
- **Backend (NL postgres):** `UPDATE vpn_servers SET is_active=false WHERE id IN (1, 3)` (Russia→DE relay + Germany standard exit), `relay_exit_peers` connected rows cleaned.
- **iOS build-85:** `applyServerSelectionIfLive` — если `configStore.selectedServerTag` не находится ни в одной группе нового /v1/config, сбрасывает на `nil` → Auto. Без этого fix'а UI лгал "🇩🇪 Германия" пока трафик уходил через NL.
- **Остаточные DE-ссылки в коде** (не критично): `Tests/UnitTests/*` использует `de-direct-de` / `de-via-msk` как data fixtures для unit-тестов — безопасно. `RealTrafficStallDetector.swift` docstring приводит DE как пример формата лог-строк — безопасно.

### Грабли
- Не "чистить" DE из тестов — они валидируют `ServerTagShape` парсинг на формате `cc-protocol-host`, не presence DE в проде.
- SPB relay `185.218.0.43` (INFRA-SPB-01) маппил на DE — после `is_active=false` на relay_exit_peers лишний хвост не отдаётся в /v1/config.

## 2026-05-25: iOS виджет показывает "Защищено" хотя VPN отключён

### Проблема
Build 83: тап на shield-кнопке widget'а → widget мгновенно показывает "Защищено 0:06" с растущим таймером, главное приложение показывает "ВЫ ОТКЛЮЧЕНЫ". Расхождение остаётся навсегда до перезапуска.

### Причина
`ToggleVPNIntent.perform()` запускается в widget-extension процессе. После `try session.startTunnel(options: nil)` (который НЕ throws сразу — это "queued") вызывался `VPNControl.publishOptimisticState(connected: true)` → пишет `vpnConnectedAtKey = now` в App Group, widget читает → "Защищено". Если реальный connect упал асинхронно (другой VPN, On-Demand, config error), widget process не наблюдает outcome → optimistic write никогда не отменяется. Главное приложение очищало `vpnConnectedAtKey` в `handleStatus()` на `.disconnected`, но НЕ дёргало `WidgetCenter.reloadAllTimelines()` → widget узнавал только через свою 30-мин timeline policy.

### Решение (build 84)
1. `Shared/VPNControlIntents.swift` — убрал `publishOptimisticState(connected: true)` из `.start` case. Только `WidgetCenter.shared.reloadAllTimelines()` (на случай stale read). Authoritative truth = `ExtensionProvider.publishWidgetState()`, пишет когда sing-box реально стартанул (~1-3с после тапа). Optimistic `.stop` оставлен — `stopVPNTunnel` essentially мгновенный на kernel-уровне.
2. `MadFrogVPN/Models/AppState.swift handleStatus()` — теперь `WidgetCenter.shared.reloadAllTimelines()` вызывается на каждой смене статуса. Дёшево: WidgetCenter сам rate-limit'ит.

### Анти-паттерн
**Не write `connected: true` optimistic из widget process без observation на реальный outcome.** startTunnel — это "iOS queued", не "tunnel up". Если в будущем понадобится мгновенный feedback при тапе — нужен отдельный `widget.pending_until` deadline-ключ, который автоматически expires если authoritative write не пришёл за N секунд.

## 2026-04-24: DE (OVH Frankfurt) заблокирован на RU LTE — все протоколы мёртвые

### Проблема
На RU мобильных операторах (MTS / Beeline / MegaFon / T2) при выборе DE в клиенте
страницы не грузятся ни через VLESS (TCP:443), ни через H2 (UDP:443), ни через
TUIC (UDP:8443). При этом NL (Timeweb, `147.45.252.234`) грузит чисто.
На WiFi DE работает.

### Причина
RU мобильные carrier-level блокируют OVH AS16276 ranges — TCP SYN к
`162.19.242.30` дропается или RST на ASN-уровне. UDP аналогично. NL Timeweb AS9123
пока не в блок-листах.

Ложный диагноз «DE выбран, exit IP NL» был побочкой OOM-reset libbox
debug (`48a93b9`, build 30): после OOM Auto urltest переоценивал и падал на NL,
whoer.net видел NL exit. Поправлено на клиенте, ошибка селектора
не воспроизводится.

### Решение (применено 2026-04-24)
Смягчения в коде — полный фикс требует новой ноды off-OVH (см. ROADMAP → Now → Infra P0):

1. **`backend/internal/vpn/clientconfig.go`** — `isNLServer()` + `sort.SliceStable`
   ставит NL-outbound'ы первыми в `Auto` urltest. sing-box пингует первый в
   списке чаще, плюс при ties выбирает первый. Non-RU пользователи не
   регрессируют: urltest всё равно выбирает лучший leg по latency.
2. **`clients/apple/MadFrogVPN/Models/APIClient.swift`** — `isRURegion`
   (`Locale.current.region?.identifier == "RU"`) фильтрует `162.19.242.30` из
   direct-IP race-legs. На RU Apple Sign-In / magic link / config fetch
   перестаёт ждать 6s DE-timeout'а, race сходится на NL/SPB/primary.
3. **ROADMAP Infra P0** — кандидаты Hetzner Helsinki / Falkenstein, DO / Vultr,
   acceptance criteria, миграционный план.

### Грабли
- Не диагностируйте это повторно как баг селектора или cluster sync — логика
  `selectServer` и `selectOutbound` корректна.
- `api.madfrog.online` идёт на MSK relay (217.198.5.52) через DNS A-record
  напрямую, без Cloudflare proxy. CF не при чём.
- libbox `debug=true` OOM уже пофикшен (`48a93b9`, build 30).
- vpn_username cluster sync conflict демотирован до warn — шум, а не баг.

### Проверка
- Build ≥ 31 с фиксом 1+2: на RU-LTE первое подключение через Auto выбирает NL в
  <5s. Apple Sign-In укладывается в <8s вместо ~25s.
- WiFi-поведение не меняется: urltest выбирает DE если ping меньше.

---

## 2026-04-15: Routing mode на iOS — Clash API не работает, только libbox unix socket

### Проблема
Реализовал 3-режимный split tunneling (smart / ru-direct / full-vpn) через три `selector` аутбаунда в конфиге (`RU Traffic`, `Blocked Traffic`, `Default Route`). Переключение в живую попытался сделать через Clash API PUT `/proxies/<tag>` на `127.0.0.1:9091` из расширения. На iPhone постоянно:
```
setClashSelector error: NSURLErrorDomain Code=-1004
routing_mode → smart: partial/failed
```

### Причина
`clients/apple/Shared/ConfigSanitizer.swift` **вырезает** `experimental.clash_api` из конфига перед передачей в sing-box:
> iOS sandbox blocks TCP bind inside the NetworkExtension process.

Clash API на iOS физически не поднимается — любой HTTP на `127.0.0.1:9091` уходит в Connection Refused. Расширению нельзя биндить TCP-сокеты; только unix-сокеты в shared container.

### Решение
Использовать `LibboxCommandClient.selectOutbound(groupTag:, outboundTag:)` через unix socket `command.sock` — та же инфраструктура что уже работает для live server switch в `AppState.selectServer`.

Архитектура:
- `clients/apple/Shared/RoutingMode.swift` — enum с `selectorTargets: [(selector, target)]` для каждого режима
- `clients/apple/ChameleonVPN/Models/AppState.swift::setRoutingMode(_:)` — пишет `routingMode` в shared UserDefaults + зовёт `commandClient.selectOutbound` × 3 (по одному на каждый селектор). Если `commandClient.isConnected == false` — только персистит.
- `handleStatus` при `.connected` вызывает `applyRoutingModeIfLive` через 400мс после того как command client поднимется.
- `clientconfig.go` больше **не содержит** `experimental.clash_api` — всё равно срезается.
- `ExtensionProvider.swift` больше не обрабатывает `routing_mode:` IPC-сообщение — вся логика в main app.

### Грабли
- Сигнатура `Picker(selection:)` в SwiftUI для `LocalizedStringKey` vs `String`: метод `routingModeHint` должен возвращать `LocalizedStringKey`, иначе `cannot convert return expression of type 'LKey' to return type 'String'`.
- Сначала пробовал `sendProviderMessage` IPC (main → extension → Clash API), потом — прямой URLSession в расширении. Оба пути сломаны одинаково — Clash API вообще нет.

## 2026-04-15: В режиме «РФ напрямую» 2ip.ru показывал VPN IP

### Проблема
Юзер в режиме `ru-direct`: ожидал что `.ru` сайты идут direct → 2ip.ru должен показать реальный российский IP. Показывал `162.19.242.30` (OVH DE).

### Причина
В route rules был только `rule_set: geoip-ru` — он матчит по **IP**, а не по домену. Многие .ru сайты хостятся за CloudFlare / anycast CDN, их IP не попадает в `sing-geoip/geoip-ru.srs` → правило не матчит → запрос падает на `final: Default Route` = `Proxy` в ru-direct.

### Решение
В `clientconfig.go` добавил route rule **перед** `geoip-ru`:
```go
{ DomainSuffix: []string{".ru"}, Outbound: "RU Traffic" }
```
Порядок важен:
1. `refilter` (RKN blocked) → `Blocked Traffic` (чтобы .ru блокированные сайты всё равно шли через VPN)
2. `.ru` domain → `RU Traffic` (наш новый rule)
3. `geoip-ru` → `RU Traffic` (catch-all для не-.ru доменов на RU IP)

После фикса: `match[7] domain_suffix=.ru => route(RU Traffic)` → direct.

## 2026-04-15: Timeweb IP выглядит как российский в GeoIP-базах

### Симптом
whoer.net / 2ip.ru на NL2 ноде (`147.45.252.234`, Timeweb) показывали "Россия, Timeweb, LLP" — хотя сервер физически в Нидерландах.

### Причина
Timeweb LLC — российская компания, их IP-диапазоны многие GeoIP-базы (включая MaxMind free) классифицируют как RU, хотя ASN может быть в ЕС.

### Следствие для user-facing диагностики
Нельзя использовать whoer/2ip.ru как единственный способ проверить что VPN работает для NL-ноды — юзер может решить что ничего не включилось. Для честной проверки лучше открывать сайт вне Timeweb ASN (`ipleak.net`, `ifconfig.me`).

## 2026-04-15: UI-чип «Сервер» расходился с реально используемым аутбаундом

### Симптом
Юзер тапнул DE в списке серверов, чип показывает "VLESS 🇩🇪 Germany". Но whoer.net выдаёт IP NL2-ноды — трафик реально идёт на другой сервер.

### Причина
`VPNStateHelper.selectedServerName` читал `app.configStore.selectedServerTag` — это "что юзер хотел", а не "что реально активно". Если `Proxy` селектор в `command server` сейчас указывает на `Auto` (который пикнул NL2 по urltest), чип всё равно показывает последний ручной выбор.

### Решение
В `MainView.swift::VPNStateHelper.selectedServerName` — сначала читаем живое состояние:
```swift
if isConnected(app), app.commandClient.isConnected,
   let live = app.commandClient.selectedServer {
    return live.tag
}
// fallback to configStore.selectedServerTag
```
`commandClient.selectedServer` парсит `Groups` из libbox и возвращает реально выбранный аутбаунд в цепочке селекторов (учитывает Proxy→Auto→server).

## 2026-04-14: Админка показывала VPN-локацию вместо реальной + расширенная телеметрия

### Проблема
В `/clients/admin/app/users` поле "Location" у подключённых пользователей показывало Лимбург-на-Лане / OVH DE — это наш exit-node, а не реальная страна устройства. Геолокация бралась по `last_ip`, который при активном VPN = IP нашего сервера.

### Решение
1. **Миграция 006** (`migrations/006_user_context.sql`) — добавлены колонки: `initial_ip`, `initial_country{,_name}`, `initial_city`, `timezone`, `device_model`, `ios_version`, `accept_language`, `install_date`, `store_country`
2. **`initial_*` снимается один раз** при `/auth/register` и `/auth/apple` (только для новых юзеров) — до того как клиент успеет подключиться к нашему VPN. GeoIP (`ip-api.com`) дёргается ТОЛЬКО в этот момент — раньше дёргался на каждый `/mobile/config`, что было проблемой для Apple privacy disclosure.
3. **iOS шлёт заголовки на всех API вызовах**: `X-Timezone`, `X-Device-Model` (utsname, напр. `iPhone15,2`), `X-iOS-Version`, `X-Install-Date`. Стандартные HTTP headers, не сенсоры → не требуют App Tracking Transparency. См. `clients/apple/ChameleonVPN/Models/APIClient.swift` → `DeviceTelemetry` + `applyTelemetry(to:)`.
4. **Via-VPN detection**: админка грузит `vpn_servers.host` → сравнивает с `last_ip`; если match → `is_via_vpn: true` + `via_vpn_node: "de"`, UI показывает 🛡 badge и использует `initial_country` как реальную локацию.
5. **Federated sync**: `users.updated_at` триггер бьётся на каждый TouchUserDevice, но `UpsertUserByVPNUUID` в reconcile не трогает device-колонки — они node-local. OK для текущего масштаба.

### Грабли при деплое
- Сначала добавил новые колонки в `userColumns` и `scanUser`, но забыл обновить **`scanUsers`** (отдельная функция для многострочных запросов). Бэкенд падал на старте: `number of field descriptions must equal number of destinations, got 46 and 36` в `ListActiveVPNUsers`. Если добавляешь поля в `users` — обнови **обе** функции в `internal/db/users.go`.

## 2026-04-14: Per-user traffic accounting не работал — переход на v2ray_api gRPC

### Симптомы
- В админке `/clients/admin/app/users` у всех пользователей `cumulative_traffic = 0`
- `traffic_snapshots` пустая, хотя iPhone активно ходил через VPN
- `users.last_seen` тоже не обновлялся

### Причина
Старая `StatsCollector.QueryTraffic` ходила в `clash_api /connections`, агрегировала `upload`/`download` по `metadata.InboundUser` и считала дельты против `prevTraffic` map. Но в sing-box 1.13 `clash_api /connections` — это моментальный срез **только активных** TCP-коннектов; закрытые коннекты пропадают мгновенно. VLESS Reality использует мультиплексированные короткоживущие коннекты, так что между тиками (60с) счётчики сбрасывались, и дельта всегда получалась 0 (или отрицательной — тогда отбрасывалась).

Это не баг 1.13, а фундаментальное ограничение clash_api: он предназначен для UI, а не для учёта.

### Решение: v2ray_api gRPC StatsService
sing-box унаследовал от v2ray `experimental.v2ray_api` с `stats` сервисом, который ведёт **персистентные** per-user счётчики `uplink`/`downlink`. Это единственный встроенный источник персистентного учёта в sing-box.

1. Пересобран custom sing-box fork с build tag `with_v2ray_api`:
   - На DE: `/tmp/sing-box-fork/release/DEFAULT_BUILD_TAGS_OTHERS` — добавлен префикс `with_v2ray_api,`
   - Пересборка занимает ~3 мин на DE (8 CPU), на nl2 (2GB RAM) не пробовал — вместо этого через `docker save` / `scp` / `docker load` перенёс готовый образ с DE
2. В `backend/internal/vpn/singbox.go` добавлен блок `experimental.v2ray_api` с перечислением всех user-ов (`users: []`) и inbound (`inbounds: ["vless-reality-tcp"]`)
3. Новый клиент `internal/vpn/stats_v2ray.go` ходит gRPC `QueryStats(pattern="user>>>")` и парсит имена `user>>>{username}>>>traffic>>>uplink|downlink`, считает дельты против baseline (первый вызов — baseline, возвращает nil)
4. `StatsCollector.QueryTraffic` делегирует всё в `v2rayStats`; clash_api остаётся только для `OnlineUsers` / `CurrentSpeed` / `SessionTraffic`
5. Добавлен `vpn.EngineConfig.V2RayAPIPort` + `config.VPNConfig.V2RayAPIPort` (default 8080)
6. `internal/vpn/v2rayapi/command/` — минимальный подмножество v2ray stats proto (`QueryStats` / `GetStats`), сгенерировано через `protoc --go_out --go-grpc_out`
7. Зависимости: `google.golang.org/grpc v1.76.0`, `google.golang.org/protobuf v1.36.10`

### Важные детали
- **Без `with_v2ray_api` тега** sing-box падает на старте с `v2ray api is not included in this build, rebuild with -tags with_v2ray_api` — ломает VPN. Если после обновления chameleon это случится — временно удалить `v2ray_api` блок из `/etc/singbox/singbox-config.json` и рестарт singbox, пока не пересоберёшь fork с тегом.
- **Инициализация gRPC клиента**: `grpc.DialContext` с `insecure` creds на `127.0.0.1:8080`; блок `users: []` в config обязателен — без него stats service не заводит счётчики на пользователей (даже если `enabled: true`)
- **Reset counter protection**: при рестарте sing-box счётчики обнуляются → возможна отрицательная дельта. Код возвращает абсолютное значение как дельту (treat as fresh counter). Без этого потеряем первый цикл после рестарта.
- **Reload флоу**: когда chameleon добавляет/удаляет пользователя, нужно обновить `experimental.v2ray_api.stats.users` в конфиге и сделать reload (SIGHUP или user-api replace). Сейчас users пишутся только при полной перегенерации конфига — добавление пользователя через user-api (без перегенерации) не регистрирует его в stats service, счётчики не появятся. TODO: либо всегда делать полную перегенерацию, либо исследовать можно ли подставлять users динамически.

### Проверка что работает
```bash
# На сервере
docker exec chameleon-postgres psql -U chameleon -d chameleon -c \
  "SELECT vpn_username, upload_traffic, download_traffic, timestamp FROM traffic_snapshots ORDER BY timestamp DESC LIMIT 5;"

# Логи коллектора
docker logs chameleon --since 5m 2>&1 | grep -iE "v2ray|traffic.recorded"
# Ожидаемо: "traffic recorded", users: N  (каждые 60с если есть трафик)

# Порт sing-box gRPC
ss -tlnp | grep :8080
# Ожидаемо: 127.0.0.1:8080 LISTEN sing-box
```

### Деплой на DE и nl2
DE (пересобрали fork in-place):
```bash
cd /tmp/sing-box-fork
echo "with_v2ray_api," > release/DEFAULT_BUILD_TAGS_OTHERS  # prepend
nohup make release > /tmp/singbox-build.log 2>&1 &  # ~3 min
docker build -t sing-box-fork:v1.13.6-userapi .
./deploy.sh de  # деплоит новый chameleon
docker restart chameleon
docker rm -f singbox && scripts/singbox-run.sh
```

nl2 (через образ с DE — нет ресурсов на сборку):
```bash
# На DE:
sudo docker save -o /tmp/chameleon-images.tar sing-box-fork:v1.13.6-userapi backend-chameleon:latest
sshpass -p '<nl2 pwd>' scp /tmp/chameleon-images.tar root@147.45.252.234:/tmp/

# На nl2:
docker load -i /tmp/chameleon-images.tar
cd /opt/chameleon/backend && docker compose up -d --force-recreate --no-deps chameleon
docker rm -f singbox && bash scripts/singbox-run.sh
```

⚠️ `docker compose restart chameleon` **не** подхватывает новый digest одного и того же тега — нужен `--force-recreate`.

---

## 2026-04-14: Cluster sync стёр Reality ключи в production БД (миграция NL)

### Симптомы
- При деплое свежей NL-ноды (nl2, `147.45.252.234`) на DE и NL-1 началось падение chameleon с `reality private key not found`
- iOS: Germany direct и Russia→NL стали возвращать `reality verification failed`

### Причина
`backend/migrations/init.sql` сидит `vpn_servers` строки для `de`, `nl`, `relay-de`, `relay-nl` **до** того как `ALTER TABLE` добавляет колонки `reality_private_key` / `reality_public_key`. На свежей БД (nl2) эти строки получаются с пустыми ключами. Cluster syncer вызывает `UpsertServerByKey` с политикой "latest updated_at wins" и пушит пустые строки на DE/NL-1, перезаписывая реальные Reality ключи.

Дополнительно: бэкап от 2026-04-13, из которого я восстанавливал ключи, содержал перепутанные public keys между `de`/`relay-de` и `nl`/`relay-nl` — т.е. relay-строки хранили настоящие ключи серверов, а direct-строки — мусор. Почему так — неизвестно (вероятно давняя ручная правка). Это было скрыто тем что iOS кеширует подписку и force-refresh делается редко.

### Как диагностировали
- `reality private key not found` на NL-1 после деплоя nl2 → стоп nl2 чтобы остановить дальнейшую порчу через sync
- Извлекли реальные private keys из живых singbox config (`/var/lib/docker/volumes/chameleon-singbox-config/_data/singbox-config.json`)
- Вывели public keys через `docker run --rm teddysun/xray xray x25519 -i <priv>` и сверили с БД
- Это показало что строки в БД имеют ключи, не соответствующие ни одному живому серверу

**⚠️ 2026-05-26 (audit CRIT-001):** конкретные значения private/public keys ранее упоминались в этом блоке. Удалены при ротации — production Reality keypairs (DE, NL2, MSK-relay) считались скомпрометированными из-за того что были закоммичены в test fixtures (`reality_keys_test.go`). Не возвращать конкретные значения в документацию ни при каких условиях.

### Решение
1. Остановили chameleon на nl2 чтобы прервать sync
2. Восстановили vpn_servers из DB backup (`/var/backups/chameleon/chameleon_20260413_030001.sql.gz` на NL-1)
3. Поправили перепутанные строки: `de.reality_public_key = ug2jX3u...`, `relay-nl.reality_public_key = q2prwNjF...` (после миграции relay-nl → `99tZN...` от nl2)
4. Перезагрузили chameleon на всех нодах

### Что надо починить (TODO)
- **`migrations/init.sql`** не должен сидить `vpn_servers` строки без reality_* полей. Либо убрать seed совсем (пусть заливается вручную), либо объединить schema в одну миграцию, чтобы ALTER TABLE прошёл до INSERT.
- **`cluster/sync.go` `UpsertServerByKey`** должен защищать непустые поля от перезаписи пустыми — правило "latest wins" опасно когда "latest" — это свежесозданная строка с дефолтами. Вариант: `COALESCE(NULLIF(EXCLUDED.reality_public_key, ''), vpn_servers.reality_public_key)`.
- Добавить проверку при старте chameleon: если `FindLocalServer` вернул строку с пустым private key — отказаться стартовать вместо того чтобы работать с fallback на env.

### Полезно
- Проверять фактическую связку pub/priv на сервере: `docker run --rm teddysun/xray xray x25519 -i <private_key>` 
- Не доверять ни одному значению в `vpn_servers.reality_public_key` — всегда сверять с реальным singbox конфигом ноды

---

## 2026-04-12: iOS — переключение сервера не меняет трафик + 13-секундный фриз UI

**Коммит:** `90c4f34` — iOS: fix server switching, UI stalls, and tunnel logging

### Симптомы
1. При переключении страны (например NL → DE) UI показывает что Germany выбрана, но реальный IP/трафик остаётся через NL
2. Каждое переключение сервера вызывает 10–13 секунд фриза UI, в течение которых тапы не регистрируются
3. В debug-логе видно `cmdClientConnected=false` в момент `selectServer`

### Причины (две связанные)

#### 1. Main app не вызывал `LibboxSetup` → CommandClient никогда не коннектился к gRPC
- **Проблема:** `LibboxNewCommandClient` ищет Unix-сокет по пути `basePath/command.sock`, где `basePath` задаётся через `LibboxSetup()`. Extension (`PacketTunnel`) его вызывал, а main app — нет. Комментарий в `CommandClient.swift` утверждал обратное, но в `ChameleonApp.swift` вызова не было.
- **Следствие:** gRPC handshake с CommandServer всегда падал → `isConnected=false` → `selectServer` уходил в fallback-ветку полного teardown туннеля (disconnect → wait → reconnect), откуда и 13 секунд фриза.
- **Решение:** Добавлен вызов `LibboxSetup` в `ChameleonApp.init()` с теми же `basePath`/`workingPath`/`tempPath`, что использует extension (через `AppConstants`).
- **Файл:** `clients/apple/ChameleonVPN/ChameleonApp.swift`

#### 2. `selectOutbound` не закрывал существующие соединения
- **Проблема:** sing-box `selectOutbound` меняет указатель селектора только для **новых** TCP-стримов. Уже установленные соединения (например, keep-alive Safari-вкладки к Cloudflare) продолжали идти через старый outbound. Визуально — "сервер сменился, IP не изменился".
- **Решение:** После успешного `selectOutbound` вызывается `client.closeConnections()` — принудительный разрыв всех активных стримов. Они реконнектятся уже через новый outbound.
- **API:** `LibboxCommandClient.closeConnections(_:)` — доступен в libbox 1.13.5
- **Файл:** `clients/apple/ChameleonVPN/Models/CommandClient.swift`

### Как диагностировали
- Подключили iPhone 16 Pro по кабелю, `xcrun devicectl device process launch --console` + `idevicesyslog` для live-стрима
- Искали причину `cmdClientConnected=false` в коде → нашли что `LibboxSetup` вызывается только в extension, но не в main app
- Проверили `Libbox.objc.h` — нашли `closeConnections:` в `LibboxCommandClient`

### Полезные команды для подобного
```bash
# Список устройств
xcrun devicectl list devices

# Сборка + установка на устройство
xcodebuild -project Chameleon.xcodeproj -scheme Chameleon -configuration Debug \
  -destination 'id=<DEVICE_UDID>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE_UDID> \
  ~/Library/Developer/Xcode/DerivedData/Chameleon-*/Build/Products/Debug-iphoneos/Chameleon.app

# Стрим stdout приложения
xcrun devicectl device process launch --device <DEVICE_UDID> \
  --console --terminate-existing com.chameleonvpn.app

# Стрим syslog (нужен brew install libimobiledevice)
idevicesyslog -m "Chameleon" -m "PacketTunnel"
```

---

## 2026-04-08: Germany (DE) server — страницы не грузятся при прямом подключении

**Коммит:** `0290013` — Fix: server selector reconnect + Auto button + debug log improvements

### Симптомы
- При выборе "🇩🇪 Germany" напрямую — страницы не грузятся, sing-box показывает `EOF` и `dropped due to flooding`
- При подключении через "🇷🇺 Russia → DE" (relay) — всё работает
- urltest для Germany то проходит, то таймаутит (`context deadline exceeded`)

### Причины (найдено 3)

#### 1. Xray DIRECT outbound без `domainStrategy: UseIPv4`
- **Проблема:** Xray на DE сервере использовал IPv6 для исходящих соединений. IPv6 на OVH VPS частично сломан (`curl -6 https://1.1.1.1` → fail, IPv6 к google 6x медленнее IPv4)
- **Решение:** Добавлен `"settings": {"domainStrategy": "UseIPv4"}` в DIRECT outbound конфиг Xray
- **Файл:** `/var/lib/docker/volumes/chameleon-xray-config/_data/config.json` на DE сервере

#### 2. Xray в Docker bridge network вместо host mode
- **Проблема:** Xray запущен в docker-compose с `ports: ["2096:2096"]` (bridge network, IP 172.18.0.3). Docker NAT добавляет overhead и ограничивает throughput для VPN трафика. Все пакеты проходят через conntrack → flooding
- **Решение:** Заменено на `network_mode: host` в docker-compose.yml. Удалены `ports`, `cap_drop`, `cap_add` (не нужны в host mode)
- **Файл:** `/home/ubuntu/chameleon/backend/docker-compose.yml` на DE сервере

#### 3. iOS: кнопка "Auto" не вызывала reconnect
- **Проблема:** При переключении Germany → Auto, VPN оставался на Germany без переподключения. Кнопка Auto просто ставила `selectedServerTag = nil` без вызова `selectServer()`
- **Решение:** Auto теперь вызывает `selectServer(groupTag: "Proxy", serverTag: "Auto")` с полным disconnect/reconnect циклом

### Диагностика (команды для будущих проблем)

```bash
# DE (162.19.242.30) RETIRED 2026-05-25 — credentials scrubbed.

# Проверить Xray network mode
sudo docker inspect xray --format='NetworkMode: {{.HostConfig.NetworkMode}}'
# Должно быть: host

# Проверить Xray DIRECT outbound
sudo docker exec xray cat /etc/xray/config.json | python3 -c "
import json,sys
c=json.load(sys.stdin)
for o in c.get('outbounds',[]):
    if o.get('tag')=='DIRECT': print(json.dumps(o, indent=2))
"
# Должно содержать: "domainStrategy": "UseIPv4"

# Проверить IPv4/IPv6
curl -4 -sk --max-time 5 -w "HTTP:%{http_code} TIME:%{time_total}s\n" -o /dev/null https://www.gstatic.com/generate_204
curl -6 -sk --max-time 5 -w "HTTP:%{http_code} TIME:%{time_total}s\n" -o /dev/null https://www.gstatic.com/generate_204

# Проверить Xray подключения (без api spam)
sudo docker logs xray --since 2m 2>&1 | grep -v api | tail -20

# Включить debug логирование Xray (временно!)
# Изменить loglevel на "debug" в config.json, docker restart xray
```

### Ключевые IP

| Сервер | IP | Порт Xray | SSH |
|---|---|---|---|
| DE (Germany) | 162.19.242.30 | 2096 | ubuntu + password |
| Main (Russia) | 185.218.0.43 | 443 | — |
| NL (Netherlands) | 194.135.38.90 | 2096 | — |

### iOS-код изменения

- `AppState.swift` — `selectServer()`: добавлен Auto detection, wait for disconnect loop, logging
- `AppState.swift` — `buildConfigWithSelector()`: проверка members selector'а, logging
- `MainView.swift` — Auto button вызывает `selectServer()` вместо прямого сброса тега
- `DebugLogsView.swift` — lazy rendering, Claude report builder, ANSI stripping

---

## 2026-04-24: Cluster sync захламил логи `duplicate key` 23505 на vpn_username

### Симптом
DE+NL `chameleon` контейнеры спамили `error` каждые 5 секунд:
```
ERROR cluster.api  failed to upsert pushed user
  vpn_uuid=245aeec7-…  error=ERROR: duplicate key value violates unique constraint "idx_users_vpn_username" (SQLSTATE 23505)
```

### Root cause
`generateVPNUsername(deviceID)` возвращал `"device_" + sha256(device_id)[:8]` — **детерминированно от device_id**. Значит:
1. Юзер регистрируется на DE → `vpn_uuid=A, vpn_username="device_xyz"`
2. Юзер делает `deleteAccount` → row остаётся (soft-delete)
3. Юзер регистрируется снова → новый `vpn_uuid=B`, тот же `vpn_username="device_xyz"` → unique-index violation
4. Cluster sync пытается распространить новую row на peer, peer тоже падает на индексе

### Fix (commits `e8449af` + `e6db13d`)
1. **Не маскировать ошибку** в логах — добавить `cluster/errors.go isDuplicateVPNUsername`, понизить только этот specific 23505 с `error` → `warn`. Real failures (DB connection lost, schema drift) сохраняют error level.
2. **Фикс root cause**: `generateVPNUsernameFromUUID(uuid)` — хеширует уже-сгенеренный `vpn_uuid` (crypto-random 128 bits → unique). Старая `generateVPNUsername(string)` удалена.
3. UpsertUserByVPNUUID `ON CONFLICT (vpn_uuid)` оставлен как было — теперь конфликта по username не будет.

### Урок
> Любое значение которое попадает в **unique** DB index не должно быть детерминированным от чего-то что юзер контролирует или может повторно ввести. Username = derive from per-row crypto-random, не от device_id / IP / любого external input.

---

## 2026-04-24: sing-box double `Wait()` — потенциальный deadlock + zombie процесс

### Симптом
Не наблюдался в проде (ловит go-reviewer agent статически). Но при scenario `Stop()` во время `reload` обе горутины делали `cmd.Wait()` на одном `os.Process` — UB по Go runtime, в худшем случае deadlock на `e.mu`.

### Root cause
`startProcessLocked()` запускал goroutine с `e.cmd.Wait()`. `stopProcessLocked()` запускал ВТОРУЮ goroutine с `e.cmd.Process.Wait()`. Process.Wait() можно вызвать только один раз — кто выиграл, оставляет другой блокированным или возвращает мусор. Плюс monitor goroutine пытался брать `e.mu.Lock()` для чтения `e.running`, пока `Stop()` уже держал `e.mu` — lock-channel deadlock.

### Fix (commit `e6db13d`)
- `SingboxEngine` получил поле `procDone chan struct{}`.
- `startProcessLocked` создаёт `procDone` ДО запуска monitor.
- Monitor: `cmd.Wait()` → `close(procDone)` → читает `e.running` под `RLock` (не `Lock`).
- `stopProcessLocked`: `<-procDone` (не вызывает `Process.Wait()` сам).

### Урок
> `os/exec.Cmd.Process.Wait()` — **once-and-only-once**. Используй один waiter goroutine + done channel, не два разных Wait() на разных стороны кода.

---

## 2026-04-24: Keychain delete-then-add race в PacketTunnel extension

### Симптом
Не наблюдался у юзеров, но gap между `SecItemDelete` и `SecItemAdd` мог обнулить credential на момент чтения из extension (тoкен выглядит «отсутствующим» 1-50ms, потом возвращается).

### Fix (commit `e8449af`)
`KeychainHelper.save()` теперь **`SecItemUpdate` сначала, fallback на `SecItemAdd`** если `errSecItemNotFound`. Atomic на уровне Security framework — нет окна когда ключ не существует.

### Урок
> При rotation секретов в shared store (Keychain, UserDefaults App Group, файлы), всегда update-or-insert, не delete-then-add.

---

## 2026-04-24: ExtensionPlatformInterface FileHandle race на `singbox.log`

### Симптом
Когда libbox активно логирует (debug mode), записи в `singbox.log` могли interleave и corrupt файл. iOS extension memory pressure плюс невалидные записи в логе осложняли диагностику других проблем.

### Root cause
`writeDebugMessage(_:)` вызывается libbox с произвольных background threads. Открывал `FileHandle`, делал `seekToEndOfFile`, `write`, `closeFile` — без всякой синхронизации. Concurrent emissions писали друг через друга.

### Fix (commit `e6db13d`)
Serial `DispatchQueue(label: "vpn.madfrog.singbox-log", qos: .utility)` сериализует все записи. Современный API: `try? handle.seekToEnd()`, `try? handle.write(contentsOf:)`.

### Урок
> `FileHandle` НЕ thread-safe. Любая обёртка над файлом из background callbacks должна иметь собственный serial queue.

---

## 2026-04-24: Apple StoreKit verification была flagged как «отсутствует» — на самом деле есть

### Что произошло
Security audit агент в первом проходе сказал: «backend doesn't verify Apple transactions». Я уже собирался имплементить. Прочитал `backend/internal/payments/apple/verify.go` — там полная JWS verification через `awa/go-iap` (signature chain leaf → Apple root, bundle id check, environment check, expiry, productId).

### Урок
> При запуске нескольких reviewer-агентов **не доверять однозначно** их findings, а проверять цитатами в коде. Особенно claims вида «X не реализовано» — может быть ложное срабатывание из-за частичного покрытия агентом большого пакета.

---

## 2026-04-24: nginx HTTP→HTTPS редирект и Cloudflare flexible mode

### Гocha
Прямолинейный `if ($scheme = http) { return 301 https://...; }` за Cloudflare с `SSL=flexible` ловит **redirect loop**: CF принимает HTTPS, к origin идёт HTTP, origin шлёт 301 на HTTPS, CF получает редирект и кидает обратно к origin.

### Fix (commit `fdef123`)
- Edge proxies (CF) шлют `X-Forwarded-Proto: https` когда сами терминируют TLS.
- Использовать **этот header**, не `$scheme`:
```nginx
set $is_secure 1;
if ($http_x_forwarded_proto != "https") { set $is_secure 0; }
if ($remote_addr ~ "^127\.|^10\.|^172\.16\.|^192\.168\.") { set $is_secure 1; }

location /admin/app/ {
    if ($is_secure = 0) { return 301 https://$host$request_uri; }
    ...
}
```
- Применять только к admin path (не глобально), чтобы Apple Universal Links AASA file (`/.well-known/apple-app-site-association`) и landing page не страдали — Apple валидатор не follow redirects.

---

## 2026-04-24: Build 27 уехал в App Store через ASC API без UI

### Что работает
ASC API key + `xcodebuild -allowProvisioningUpdates -authenticationKeyID/IssuerID/Path` достаточно чтобы автономно:
1. `xcodegen generate` → пересобрать xcodeproj из `project.yml`
2. `xcodebuild archive -scheme MadFrogVPN -destination 'generic/platform=iOS' -allowProvisioningUpdates ...` — Xcode сам запросит/создаст Distribution cert + provisioning profile
3. `xcodebuild -exportArchive -exportOptionsPlist ExportOptions.plist` (с `method=app-store-connect`, `destination=upload`) — подпишет, упакует, загрузит в один шаг

ExportOptions.plist в репо. ASC ключ в `~/.secrets.env`.

### Что НЕ автономно
- **Submit for review** — клик в ASC web UI (можно через ASC API `POST /v1/preReleaseVersions`, но требует дополнительной настройки полей метаданных).
- **Distribution cert в Keychain** — нет в локальном Keychain не нужен, Xcode получает временный cert через Connect API.

### Beta groups
Build 27 прикреплён к двум группам через ASC API:
- `Internal Testers` (id `19b338f9-…`) — internal=True, доступен сразу.
- `Public Beta` (id `02d701b4-…`) — internal=False, требует Beta App Review (~24h).
Скрипт прикрепления: см. эту сессию (Python + PyJWT + ES256 → POST `/v1/betaGroups/{id}/relationships/builds`).
