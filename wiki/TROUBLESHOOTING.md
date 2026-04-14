# Chameleon VPN — Troubleshooting

## 2026-04-14: Cluster sync стёр Reality ключи в production БД (миграция NL)

### Симптомы
- При деплое свежей NL-ноды (nl2, `147.45.252.234`) на DE и NL-1 началось падение chameleon с `reality private key not found`
- iOS: Germany direct и Russia→NL стали возвращать `reality verification failed`

### Причина
`backend-go/migrations/init.sql` сидит `vpn_servers` строки для `de`, `nl`, `relay-de`, `relay-nl` **до** того как `ALTER TABLE` добавляет колонки `reality_private_key` / `reality_public_key`. На свежей БД (nl2) эти строки получаются с пустыми ключами. Cluster syncer вызывает `UpsertServerByKey` с политикой "latest updated_at wins" и пушит пустые строки на DE/NL-1, перезаписывая реальные Reality ключи.

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
- **Файл:** `apple/ChameleonVPN/ChameleonApp.swift`

#### 2. `selectOutbound` не закрывал существующие соединения
- **Проблема:** sing-box `selectOutbound` меняет указатель селектора только для **новых** TCP-стримов. Уже установленные соединения (например, keep-alive Safari-вкладки к Cloudflare) продолжали идти через старый outbound. Визуально — "сервер сменился, IP не изменился".
- **Решение:** После успешного `selectOutbound` вызывается `client.closeConnections()` — принудительный разрыв всех активных стримов. Они реконнектятся уже через новый outbound.
- **API:** `LibboxCommandClient.closeConnections(_:)` — доступен в libbox 1.13.5
- **Файл:** `apple/ChameleonVPN/Models/CommandClient.swift`

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
