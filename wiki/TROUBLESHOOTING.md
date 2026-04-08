# Chameleon VPN — Troubleshooting

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
