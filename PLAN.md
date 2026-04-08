# Chameleon — План миграции Xray -> sing-box (2026-04-09)

## Текущее состояние
- **Xray** (25.12.8) на DE:2096 и NL:2096 — основной VPN сервер
- **sing-box** (1.13.6) на DE:2094 — тестовый, с MUX
- **Кастомный образ** `sing-box-custom:v1.13.6` собран на DE с `with_v2ray_api`
- **SIGHUP reload** работает — 0ms бесшовная перезагрузка конфига
- **v2ray_api gRPC** совместим с нашим `xray_api.rs` — per-user статистика без изменений кода

## Стабильный тег: `v0.3-stable-no-flooding` (commit b385e56)

---

## Фаза 1: Backend — SingboxApi модуль

### 1.1 Новый `singbox_api.rs`
Замена `xray_api.rs` для sing-box:
- `reload()` → `docker kill -s HUP singbox` (0ms, бесшовно)
- `query_all_traffic()` → gRPC v2ray_api (тот же протокол что Xray)
- `count_online_users()` → gRPC v2ray_api
- `health_check()` → gRPC `GetSysStats` или проверка порта
- **НЕТ** `add_user()/remove_user()` — управление через конфиг + SIGHUP

### 1.2 Обновить `engine.rs`
- `build_singbox_server_config()` — добавить `experimental.v2ray_api`:
  ```json
  "experimental": {
    "v2ray_api": {
      "listen": "127.0.0.1:10085",
      "stats": {
        "enabled": true,
        "inbounds": ["vless-reality-tcp"],
        "users": ["device_xxx", ...]
      }
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": "chameleon2026"
    }
  }
  ```
- `regenerate_and_reload()` → вызывать SIGHUP вместо Xray gRPC reload
- sing-box слушает на **:2096** (тот же порт) — клиенты и relay не меняются

### 1.3 Обновить `traffic_collector.rs` и `metrics_recorder.rs`
- Указать gRPC на sing-box v2ray_api (тот же адрес 127.0.0.1:10085)
- Формат счётчиков идентичен: `user>>>name>>>traffic>>>uplink/downlink`

---

## Фаза 2: Docker инфраструктура

### 2.1 Добавить Dockerfile для кастомного sing-box
`infrastructure/singbox/Dockerfile`:
```dockerfile
FROM golang:1.25-alpine AS builder
RUN apk add --no-cache git build-base
RUN git clone --depth=1 --branch v1.13.6 https://github.com/SagerNet/sing-box.git /src
WORKDIR /src
ENV CGO_ENABLED=0
RUN TAGS="with_v2ray_api,with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,badlinkname,tfogo_checklinkname0" && \
    VERSION=$(go run ./cmd/internal/read_tag) && \
    LDFLAGS_SHARED=$(cat release/LDFLAGS) && \
    go build -trimpath -tags "$TAGS" -o /go/bin/sing-box \
    -ldflags "-X github.com/sagernet/sing-box/constant.Version=$VERSION $LDFLAGS_SHARED -s -w -buildid=" \
    ./cmd/sing-box

FROM alpine:3.20
RUN apk add --no-cache bash tzdata ca-certificates
COPY --from=builder /go/bin/sing-box /usr/local/bin/sing-box
ENTRYPOINT ["sing-box"]
```

ВАЖНО: тег `with_reality_server` удалён в 1.13.6 (объединён с `with_utls`).

### 2.2 Обновить `docker-compose.yml`
```yaml
singbox:
  build:
    context: ../infrastructure/singbox
    dockerfile: Dockerfile
  container_name: singbox
  restart: unless-stopped
  network_mode: host
  volumes:
    - singbox-config:/etc/singbox
  command: ["run", "-c", "/etc/singbox/config.json"]
```
- Отдельный volume `singbox-config` (не shared с Xray)
- `network_mode: host` обязательно

### 2.3 Убрать Xray из docker-compose (после проверки)

---

## Фаза 3: Протоколы и inbound'ы

### 3.1 Серверные inbound'ы sing-box
Заменить xray_inbounds() на singbox_inbounds() в Protocol trait:

**VLESS Reality TCP** (основной):
```json
{
  "type": "vless",
  "tag": "vless-reality-tcp",
  "listen": "::",
  "listen_port": 2096,
  "users": [...],
  "tls": {
    "enabled": true,
    "server_name": "ads.x5.ru",
    "reality": {
      "enabled": true,
      "handshake": {"server": "ads.x5.ru", "server_port": 443},
      "private_key": "...",
      "short_id": [...]
    }
  },
  "multiplex": {"enabled": true, "padding": true}
}
```

Бонус: **MUX нативно** на всех inbound'ах (sing-box ↔ sing-box).

### 3.2 Клиентский конфиг
Изменения в `singbox.rs` (генерация клиентского конфига):
- `interrupt_exist_connections: false` для urltest (стабильность при смене сервера)
- Остальное без изменений — порт 2096, VLESS Reality TCP

---

## Фаза 4: VPN стабильность (iOS)

### 4.1 Конфиг sing-box
- `interrupt_exist_connections: false` в urltest и selector
- MTU = 1400 (явно)

### 4.2 iOS NetworkExtension
- Улучшить `wake()` — проверка что соединение живое после пробуждения
- Heartbeat — периодическая проверка в фоне (каждые 60с)

---

## Фаза 5: Деплой

### 5.1 DE сервер
1. Собрать кастомный sing-box образ (уже сделано)
2. Переключить sing-box на :2096
3. Остановить Xray
4. Проверить VPN, speedtest, статистику

### 5.2 NL сервер
1. Добавить sing-box в docker-compose NL
2. Собрать образ
3. Переключить
4. Проверить

### 5.3 Relay (SPB)
- Без изменений — nginx stream на те же порты

---

## Что НЕ меняется
- iOS клиент — конфиг тот же (VLESS Reality TCP, порт 2096)
- Relay SPB nginx — те же порты
- БД users — та же таблица
- Admin API — те же эндпоинты
- Cluster sync — через БД

## Порядок выполнения
1. Фаза 1 (backend код) — можно начинать сразу
2. Фаза 2 (Docker) — параллельно с Фазой 1
3. Фаза 3 (протоколы) — после Фазы 1
4. Фаза 4 (стабильность) — параллельно
5. Фаза 5 (деплой) — после всех фаз

## Ключевые файлы
| Файл | Изменения |
|------|-----------|
| `backend/crates/chameleon-vpn/src/singbox_api.rs` | НОВЫЙ — управление sing-box |
| `backend/crates/chameleon-vpn/src/engine.rs` | Обновить config gen + reload |
| `backend/crates/chameleon-vpn/src/singbox.rs` | interrupt_exist_connections: false |
| `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs` | singbox_inbound() |
| `backend/crates/chameleon-monitoring/src/traffic_collector.rs` | Указать на sing-box gRPC |
| `backend/docker-compose.yml` | Кастомный sing-box образ |
| `infrastructure/singbox/Dockerfile` | НОВЫЙ — билд с v2ray_api |
| `apple/PacketTunnel/ExtensionProvider.swift` | Улучшить wake() |

## Исследования (завершены 2026-04-08)
- [x] SIGHUP reload — работает, 0ms
- [x] clash_api — работает, REST reload + total traffic
- [x] v2ray_api — нужен кастомный образ, собран, gRPC совместим с Xray
- [x] Стабильность iOS — interrupt_exist_connections, heartbeat, wake()
- [x] Кастомный образ sing-box — собран на DE (`sing-box-custom:v1.13.6`)
