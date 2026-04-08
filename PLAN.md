# Chameleon — План следующей сессии (2026-04-09)

## Контекст предыдущей сессии (2026-04-08)

### Что сделали
- **Flooding решён**: `no_drop: true` на QUIC reject правиле в singbox.rs (1 строка)
- **Причина flooding**: sing-box после 50 reject/30с переключал ICMP→drop, браузер ждал QUIC таймаут 3-5с на каждый ресурс
- **Скорость**: Germany direct 51 Mbps, 0% packet loss, latency 101ms
- **config_version**: добавлен timestamp в JSON + отображение в debug report
- **DE DIRECT UseIPv4**: фикс в engine.rs — больше не затирается при sync
- **sing-box сервер**: запущен на DE:2094 (для будущего MUX), рабочий
- **Appium**: настроен для remote control iPhone (Team ID: 99W3C374T2, WDA bundle: com.chameleonvpn.wda)

### Стабильный тег: `v0.3-stable-no-flooding` (commit b385e56)

### Что попробовали и НЕ работает
| Подход | Результат |
|--------|-----------|
| TUN stack `mixed` | Трафик не идёт (конфликт с NetworkExtension) |
| TUN stack `gvisor` | Flooding остаётся + ломает DE direct через Xray |
| sing-box MUX через Xray | Xray не понимает sing-box h2mux протокол |
| sing-box MUX через sing-box сервер | Работает (49 Mbps), но flooding всё равно на TUN inbound |
| XHTTP transport | sing-box HTTP ≠ Xray XHTTP (разные протоколы) |
| `reject method: "port_unreachable"` | Невалидное значение, VPN не стартует |

---

## Задачи: Наведение порядка

### Раунд 1 (параллельно)

#### 1. Убрать MTProxy с DE сервера
- SSH: `sshpass -p 'ChameleonDE2026Secure' ssh ubuntu@162.19.242.30`
- Найти MTProxy контейнер/процесс на порту 443 TG
- Остановить, убрать из автозагрузки
- Проверить что порт 443 освободился

#### 2. Убрать порт 2095 из Xray конфига
- Порт 2095 (VLESS TCP MUX) добавлен вручную через `docker exec` + `docker cp`
- При следующем `sync_config()` backend перезапишет конфиг и 2095 исчезнет
- Проверить что engine.rs НЕ генерирует inbound на 2095 (он не должен)
- Перезапустить Xray чтобы конфиг обновился

#### 3. Убрать MUX код из Rust
- `singbox.rs`: удалить генерацию MUX outbound'ов (tcp-mux transport), auto_tags
- `vless_reality.rs`: удалить `tcp-mux` ветку в singbox_outbound(), порт 2094 hardcode
- Оставить `no_drop: true` — это единственное полезное изменение
- Конфиг должен стать идентичным v0.1-stable + no_drop

#### 4. Обновить libbox iOS до 1.13.6
- Скачать libbox 1.13.6 xcframework с GitHub releases
- Заменить в `apple/Frameworks/Libbox.xcframework/`
- Пересобрать iOS приложение: `xcodebuild -scheme Chameleon -destination 'id=00008140-001A298A3640801C'`
- Установить: `xcrun devicectl device install app`

#### 5. Обновить sing-box сервер на DE до 1.13.6
- `docker-compose.yml`: `ghcr.io/sagernet/sing-box:v1.13.5` → `v1.13.6`
- Деплой + перезапуск

#### 6. Обновить wiki
- wiki/wiki.md: актуальная архитектура, flooding fix, версии, Appium
- wiki/TROUBLESHOOTING.md: добавить flooding fix

### Раунд 2 (после Раунда 1)

#### 7. Коммит + деплой + проверка
- Один чистый коммит со всеми cleanup изменениями
- Деплой на DE
- Проверить: VPN подключается, speedtest 50+ Mbps, нет flooding
- Создать тег `v0.4-clean`

---

## Будущие задачи (не в этой сессии)

### Миграция на sing-box сервер
- sing-box уже на DE:2094, протестирован
- Нужно: перевести основной трафик с Xray (2096) на sing-box
- Поставить sing-box на NL
- Убрать Xray когда всё стабильно

### Архитектура: убрать центральную зависимость от DE
- Сейчас DE = master (Postgres, Redis, API, Admin)
- Цель: каждая нода автономна с локальной БД
- Двусторонний sync между нодами

### iOS приложение
- config_version отображается в debug report (нужен rebuild)
- Версионность приложения (CFBundleVersion increment)

---

## Ключевые файлы

| Файл | Роль |
|------|------|
| `backend/crates/chameleon-vpn/src/singbox.rs` | Генерация sing-box клиентского конфига |
| `backend/crates/chameleon-vpn/src/engine.rs` | Xray + sing-box серверные конфиги |
| `backend/crates/chameleon-vpn/src/protocols/vless_reality.rs` | VLESS Reality outbound generation |
| `backend/docker-compose.yml` | Docker services (backend, xray, singbox, postgres, redis, nginx) |
| `apple/Shared/ConfigSanitizer.swift` | Убирает config_version перед sing-box |
| `apple/ChameleonVPN/Views/DebugLogsView.swift` | Debug report generation |
| `wiki/wiki.md` | Главная документация |

## Серверы

| Сервер | IP | SSH |
|--------|-----|-----|
| DE | 162.19.242.30 | `sshpass -p 'ChameleonDE2026Secure' ssh ubuntu@162.19.242.30` |
| NL | 194.135.38.90 | — |
| SPB Relay | 185.218.0.43 | — |

## iPhone
- UDID: `00008140-001A298A3640801C`
- Appium: `appium --relaxed-security`, session capabilities: xcodeOrgId=99W3C374T2, updatedWDABundleId=com.chameleonvpn.wda
