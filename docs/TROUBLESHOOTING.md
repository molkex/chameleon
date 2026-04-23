# Chameleon VPN — Troubleshooting

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
- Вывели public keys через `docker run --rm teddysun/xray xray x25519 -i <priv>`:
  - DE singbox `mMQQZci...` → pub `ug2jX3uFFdLXih4t0O-PTRElQpAkO6v74RiRVJVvpzE`
  - NL-1 singbox `YKtG3VAu...` → pub `q2prwNjFnbWJq_P3VzkjZE9KMm32mWKMKSc-235yvWE`
- Это показало что в БД строки `de` (`opMTn_Dm...`) и `relay-nl` (`Lwt1zBDp...`) имеют ключи, не соответствующие ни одному живому серверу

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
# SSH на DE сервер
sshpass -p "ChameleonDE2026Secure" ssh ubuntu@162.19.242.30

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
