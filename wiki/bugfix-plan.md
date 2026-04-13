# Chameleon — Консолидированный план исправлений

**Дата:** 2026-04-11
**Источники:** 5 аудит-файлов (ERRORS_AUDIT, DETAILED_ANALYSIS, анализ_001, анализ_002_полный, анализ_002_200k)
**Уникальных проблем:** 42

---

## Сводка по severity и компонентам

| Компонент | Critical | High | Medium | Low | Total |
|-----------|----------|------|--------|-----|-------|
| Серверы (DE+NL) | 5 | 5 | 3 | 0 | 13 |
| iOS App | 3 | 7 | 5 | 3 | 18 |
| Go Backend | 3 | 4 | 4 | 0 | 11 |
| Admin SPA | 1 | 4 | 2 | 0 | 7 |
| Infrastructure | 2 | 3 | 2 | 0 | 7 |

---

## Фаза 0 — Немедленно (сегодня)

### SRV-01. CRITICAL: Firewall отключён на DE
- **Сервер:** DE (162.19.242.30)
- **Проблема:** iptables INPUT policy = ACCEPT, ufw inactive. Все порты открыты в интернет, включая 8000 (backend API напрямую).
- **Фикс:** `sudo ufw allow 22,80,443,2096/tcp && sudo ufw enable`
- **Статус:** DONE (2026-04-11) — ufw включён, порт 8000 разрешён только для NL и SPB relay

### SRV-02. CRITICAL: PermitRootLogin yes на NL
- **Сервер:** NL (194.135.38.90)
- **Проблема:** SSH позволяет логин под root с паролем. При утечке = полный контроль.
- **Фикс:** `PermitRootLogin prohibit-password` в sshd_config, перезапуск sshd
- **Статус:** DONE (2026-04-11) — изменено на prohibit-password, SSH ключ проверен

### SRV-03. CRITICAL: Бэкапы не работают на DE
- **Сервер:** DE
- **Проблема:** Cron указывает на `/home/ubuntu/chameleon/...` — скрипты не существуют. Папка `/var/backups/chameleon/` пуста. Нет ни одного бэкапа.
- **Фикс:** Обновить cron пути на `/opt/chameleon/backend-go/scripts/...`, проверить что бэкап создался.
- **Статус:** DONE (2026-04-11) — пути исправлены, backup dir создан, бэкап протестирован (22KB)

### SRV-04. CRITICAL: Cron сломан на NL
- **Сервер:** NL
- **Проблема:** Cron ссылается на `/root/chameleon/...` — не существует. Health-check не работает. Backup dir `/var/backups/chameleon/` не создана.
- **Фикс:** `mkdir -p /var/backups/chameleon && chmod 700 /var/backups/chameleon`, обновить пути в cron на `/opt/chameleon/...`
- **Статус:** DONE (2026-04-11) — пути исправлены, бэкап протестирован (50KB)

### SRV-05. CRITICAL: Порт 8000 открыт в интернет (оба сервера)
- **Серверы:** DE + NL
- **Проблема:** Backend API доступен напрямую (`curl http://IP:8000/health` = 200 OK), обходя nginx rate limiting и HTTPS.
- **Фикс:** Привязать chameleon к `127.0.0.1:8000` или закрыть ufw.
- **Статус:** DONE (2026-04-11) — DE: ufw deny all + allow только NL/SPB. NL: убран blanket allow, разрешён только DE IP.

---

## Фаза 1 — Эта неделя: Безопасность + критические баги iOS

### BE-01. CRITICAL: Нет верификации Apple покупок
- **Файл:** `backend-go/internal/api/mobile/subscription.go:36-94`
- **Проблема:** Сервер доверяет client-provided `transaction_id` без проверки через Apple Server API v2. Любой может продлить подписку без оплаты.
- **Фикс:** Реализовать верификацию через Apple StoreKit Server API v2.
- **Статус:** TODO

### BE-02. CRITICAL: Cluster auth отключается при пустом secret
- **Файл:** `backend-go/internal/cluster/routes.go:17-34`
- **Проблема:** Если `secret == ""` — все cluster запросы проходят без авторизации. Можно push/pull пользователей.
- **Фикс:** Reject запросы если secret не сконфигурирован.
- **Статус:** TODO

### BE-03. CRITICAL: Unauthenticated mobile config endpoint
- **Файлы:** `backend-go/internal/api/mobile/routes.go:42`, `config.go:22`
- **Проблема:** `/api/v1/mobile/config` доступен без JWT, идентификация только по query param `username`.
- **Фикс:** Защитить JWT + привязать к authenticated identity.
- **Статус:** TODO

### iOS-01. CRITICAL: Чёрный экран без WiFi (до 96 сек)
- **Файлы:** `ChameleonApp.swift:14-15`, `AppState.swift:62-67`
- **Проблема:** `isInitialized = true` ставится ПОСЛЕ `silentConfigUpdate()`. Без сети: 3 fallback URL x таймауты + retry = до 96 сек чёрного экрана.
- **Фикс:** Поставить `isInitialized = true` ДО сетевых вызовов. `silentConfigUpdate()` — в фоновый Task.
- **Статус:** TODO

### iOS-02. CRITICAL: VPN автовключается после отключения в Настройках
- **Файлы:** `VPNManager.swift:43-47, 66-72, 124`
- **Проблема:** `connect()` включает On Demand с `NEOnDemandRuleConnect()`. При отключении через Настройки iOS On Demand остаётся enabled и автоматически переподключает VPN.
- **Фикс:** В `handleStatus()` при `.disconnected` — проверять, инициировано ли из приложения. Если нет — выключать On Demand. Добавить флаг `userInitiatedDisconnect`.
- **Статус:** TODO

### iOS-03. CRITICAL: Timer memory leak в TimerView
- **Файл:** `MainView.swift:229-249`
- **Проблема:** `Timer.publish(every: 1).autoconnect()` создаётся при инициализации View, но нигде не отменяется. Каждое пересоздание = новый таймер, старые тикают в фоне.
- **Фикс:** `.onDisappear { timer.upstream.connect().cancel() }` или переписать на `TimelineView`.
- **Статус:** TODO

### INF-01. CRITICAL: Default admin password admin123
- **Файл:** `install.sh:142` (не существует)
- **Проблема:** `ADMIN_PASSWORD=admin123` — если не поменять при установке, открытый доступ к админке.
- **Фикс:** Генерировать случайный пароль или требовать ввод при установке.
- **Статус:** NOT APPLICABLE (2026-04-11) — install.sh не существует. deploy.sh берёт пароль из ~/.secrets.env через ${CHAMELEON_ADMIN_PASSWORD}, set -euo pipefail гарантирует ошибку если переменная не задана.

### INF-02. CRITICAL: Database SSL отключён
- **Файл:** `docker-compose.yml:23`
- **Проблема:** `sslmode=disable` — креды БД идут plaintext. ОК для localhost, опасно если DB вынесут.
- **Фикс:** Включить SSL или документировать что DB строго на localhost.
- **Статус:** DONE (2026-04-11) — PostgreSQL слушает только 127.0.0.1:5432, SSL не нужен. Добавлен комментарий в docker-compose.yml предупреждающий о необходимости SSL при выносе БД.

---

## Фаза 2 — Следующая неделя: Высокие проблемы

### SRV-06. HIGH: Нет fail2ban (оба сервера)
- **Проблема:** SSH и nginx без защиты от brute-force. Массовое сканирование уязвимостей.
- **Фикс:** `apt install fail2ban`, настроить jail для sshd + nginx scan-паттерны.
- **Статус:** DONE (2026-04-11)

### SRV-07. HIGH: Docker мусор ~27GB на DE, ~5GB на NL
- **Фикс:** `docker system prune -a --volumes` (с осторожностью).
- **Статус:** TODO

### SRV-08. HIGH: Нет ротации логов (оба сервера)
- **Проблема:** `/etc/logrotate.d/chameleon` не существует. Docker контейнеры без лимита логов.
- **Фикс:** Создать logrotate конфиг + настроить Docker log driver с rotation.
- **Статус:** TODO

### SRV-09. HIGH: SSL сертификат DE истекает 21 мая 2026
- **Проблема:** Certbot не установлен, сертификат через Cloudflare. Если не автообновится — сайт ляжет.
- **Фикс:** Проверить Cloudflare SSL mode, настроить автообновление origin cert.
- **Статус:** TODO

### SRV-10. HIGH: SPB Relay шлёт broken connections к NL
- **Проблема:** 185.218.0.43 (SPB Relay) создаёт невалидные REALITY handshake длительностью до 60 сек (нормально < 1с). Relay на порту :2098 перенаправляет всё без фильтрации.
- **Фикс:** Rate limit на SPB relay или проверить конфигурацию :2098.
- **Статус:** TODO

### BE-04. HIGH: Subscription expiry check missing в GetConfig
- **Файл:** `backend-go/internal/api/mobile/config.go:40,99`
- **Проблема:** Проверяет `is_active`, но не блокирует expired subscriptions (legacy endpoint — блокирует).
- **Фикс:** Добавить проверку `expires_at` в GetConfig.
- **Статус:** DONE (2026-04-11) — добавлено в рамках BE-03

### BE-05. HIGH: Viewer/Operator могут менять подписки
- **Файл:** `backend-go/internal/api/admin/users.go`
- **Проблема:** Роли viewer и operator могут вызывать extend subscription — privilege escalation.
- **Фикс:** Ограничить endpoint роль admin.
- **Статус:** DONE (2026-04-11) — добавлена проверка claims.Role != "admin" в ExtendSubscription

### BE-06. HIGH: Mobile refresh tokens многоразовые
- **Файлы:** `backend-go/internal/api/admin/auth.go:111-125` vs `mobile/auth.go:216-242`
- **Проблема:** Admin refresh token одноразовый (Redis blacklist), mobile — многоразовый до истечения (720 часов).
- **Фикс:** Реализовать одноразовые refresh tokens для mobile API.
- **Статус:** DONE (2026-04-11) — Redis blacklist (mrt:used:*), новый refresh token возвращается при обмене

### BE-07. HIGH: Нет rate limiting на /sub/:token и config endpoints
- **Файлы:** `backend-go/internal/api/server.go:130-133`
- **Проблема:** Brute-force subscription tokens и перебор username без ограничений.
- **Фикс:** Добавить rate limiting middleware.
- **Статус:** DONE (2026-04-11) — /sub/:token обёрнут в mw.RateLimit(MobilePerMinute)

### iOS-04. HIGH: 6 force unwraps в APIClient — crash risk
- **Файл:** `APIClient.swift:102, 131, 167, 172, 205, 227`
- **Проблема:** `URL(string:...)!` и `components.url!` — crash если URL невалидный.
- **Фикс:** Заменить на `guard let url = ... else { throw APIError.networkError("Invalid URL") }`.
- **Статус:** DONE (2026-04-11)

### iOS-05. HIGH: Force unwrap iter.next()! в ExtensionPlatformInterface + CommandClient
- **Файл:** `ExtensionPlatformInterface.swift:181-184, 202-205`, `CommandClient.swift:264,268`
- **Проблема:** `let prefix = iter.next()!` — crash если API libbox несогласованно.
- **Фикс:** `guard let prefix = iter.next() else { break }`.
- **Статус:** DONE (2026-04-11)

### iOS-06. HIGH: Race condition в CommandClient
- **Файл:** `CommandClient.swift:35-36, 88-95`
- **Проблема:** `connectionToken` и `connectTask` читаются из разных потоков без синхронизации.
- **Фикс:** Аннотировать `@MainActor` на CommandClientWrapper.
- **Статус:** DONE (2026-04-11)

### iOS-07. HIGH: Observer leak — NotificationCenter без deinit
- **Файлы:** `VPNManager.swift:105-113`, `AppState.swift:375-382`
- **Проблема:** Observers добавляются, но нет deinit для очистки.
- **Фикс:** Добавлен deinit с removeObserver и cancel backgroundTask.
- **Статус:** DONE (2026-04-11)

### iOS-08. HIGH: Task leak в selectServer() и handleForeground()
- **Файлы:** `AppState.swift:312, 74`
- **Проблема:** `Task {}` не сохраняется — множественные `silentConfigUpdate()` при частом foreground/background.
- **Фикс:** Единый `backgroundTask` — отменяется перед созданием нового, + Task.isCancelled check.
- **Статус:** DONE (2026-04-11)

### iOS-09. HIGH: disconnect() ошибка saveToPreferences игнорируется
- **Файл:** `VPNManager.swift:70`
- **Проблема:** `try?` проглатывает ошибку. On Demand может не выключиться.
- **Фикс:** Логирование через os.log Logger вместо try?.
- **Статус:** DONE (2026-04-11)

### iOS-10. HIGH: InsecureDelegate — TLS verification bypass (MITM)
- **Файл:** `APIClient.swift:38-48`
- **Проблема:** Fallback session принимает любой сертификат (`serverTrust`) для relay/direct-IP путей.
- **Фикс:** Намеренное поведение для direct-IP fallback. Задокументировано в коде.
- **Статус:** DONE (2026-04-11) — documented as intentional

### ADM-01. HIGH: Provider credentials в plain text
- **Файл:** `admin/src/pages/nodes.tsx:478-485`
- **Проблема:** Пароли хостинг-провайдеров видны в DOM.
- **Фикс:** Маскировать звёздочками, click to copy.
- **Статус:** DONE (2026-04-11)

### ADM-02. HIGH: Raw server errors утекают в UI
- **Файл:** `admin/src/lib/api.ts:16`
- **Проблема:** `throw new Error(await res.text())` — стек-трейсы бэкенда видны через toast.
- **Фикс:** 5xx → generic "Server error", детали в console.error.
- **Статус:** DONE (2026-04-11)

### ADM-03. HIGH: Нет CSRF защиты
- **Проблема:** POST/PUT/DELETE на cookie auth без CSRF token.
- **Фикс:** X-Requested-With header в api.ts + CSRFProtect middleware в Go backend.
- **Статус:** DONE (2026-04-11)

### ADM-04. HIGH: providerUrl без валидации в href
- **Файл:** `nodes.tsx:385-387`
- **Проблема:** Возможна инъекция `javascript:` URL.
- **Фикс:** Строгая проверка /^https?:\/\//i.test(providerUrl).
- **Статус:** DONE (2026-04-11)

### INF-03. HIGH: CSP отсутствует для admin SPA
- **Файл:** `backend-go/nginx.conf`
- **Проблема:** Нет CSP для admin SPA (API имел CSP в Go middleware).
- **Фикс:** Добавлен CSP в nginx location /admin/app/ с script-src 'self', style-src 'self' 'unsafe-inline'.
- **Статус:** DONE (2026-04-11) — unsafe-inline для style-src необходим для Tailwind CSS

### INF-04. HIGH: Docker socket mount
- **Файл:** `docker-compose.yml:20-21`
- **Проблема:** `/var/run/docker.sock` mount — при компрометации контейнера = полный контроль хоста.
- **Фикс:** Нужен r/w: используется для docker ps (метрики) и docker kill -s (singbox HUP/TERM). Задокументировано.
- **Статус:** DONE (2026-04-11) — documented, необходим для текущей архитектуры

### INF-05. HIGH: Нет resource limits на контейнерах
- **Проблема:** Ни один контейнер не имеет лимитов CPU/RAM. Утечка памяти = OOM всего сервера.
- **Фикс:** deploy.resources.limits: chameleon 512M/1cpu, postgres 256M/0.5cpu, redis 192M/0.25cpu, nginx 128M/0.25cpu.
- **Статус:** DONE (2026-04-11)

---

## Фаза 3 — Через 2 недели: Средние и низкие проблемы

### SRV-11. MEDIUM: NL — мало RAM, swap активен
- **Проблема:** 1.9 GB RAM, 34% used, swap 57 MB. При росте пользователей — риск OOM.
- **Действие:** Мониторить. При swap > 100MB рассмотреть upgrade.
- **Статус:** TODO

### SRV-12. MEDIUM: File descriptor limit = 1024 на NL
- **Проблема:** Каждое VPN-соединение = 2+ fd. Мало для VPN сервера.
- **Фикс:** Увеличить в `/etc/security/limits.conf` и Docker daemon.
- **Статус:** TODO

### SRV-13. MEDIUM: SSL между Cloudflare и DE
- **Проблема:** Certbot не установлен. Если Cloudflare SSL mode = "Flexible" — трафик открытым текстом.
- **Фикс:** Проверить Cloudflare SSL mode, настроить Let's Encrypt если нужно.
- **Статус:** TODO

### BE-08. MEDIUM: Goroutine leak в rate limiter
- **Файл:** `backend-go/internal/api/middleware/ratelimit.go:33,75`
- **Проблема:** Cleanup ticker без shutdown path.
- **Фикс:** Добавить context/stopCh для graceful shutdown.
- **Статус:** TODO

### BE-09. MEDIUM: Stop() не идемпотентен (panic on double close)
- **Файлы:** `backend-go/internal/cluster/sync.go:130`, `pubsub.go:147`
- **Проблема:** `close(stopCh)` без `sync.Once` guard.
- **Фикс:** Обернуть в `sync.Once`.
- **Статус:** TODO

### BE-10. MEDIUM: Provider пароли plaintext в БД
- **Файл:** `backend-go/internal/db/models.go:54-55`
- **Проблема:** Компрометация БД = компрометация хостинг-провайдеров.
- **Фикс:** Шифровать перед записью.
- **Статус:** TODO

### BE-11. MEDIUM: SearchUsers без лимита длины
- **Проблема:** `pattern := "%" + search + "%"` без ограничения. Длинная строка = тяжёлый ILIKE.
- **Фикс:** Ограничить длину search до 100 символов.
- **Статус:** TODO

### iOS-11. MEDIUM: Race condition в ConfigStore — миграция при чтении
- **Файл:** `ConfigStore.swift:23-44`
- **Проблема:** Два потока могут мигрировать username из UserDefaults в Keychain одновременно.
- **Фикс:** Добавить синхронизацию (lock или actor).
- **Статус:** TODO

### iOS-12. MEDIUM: Ошибки молча игнорируются (try?)
- **Файлы:** `VPNManager.swift:46,63,70`, `ExtensionPlatformInterface.swift:217`
- **Проблема:** `try?` проглатывает ошибки сохранения preferences и DNS fallback.
- **Фикс:** Логировать ошибки.
- **Статус:** TODO

### iOS-13. MEDIUM: Нет timeoutIntervalForResource в URLSession
- **Файл:** `APIClient.swift:55-62`
- **Проблема:** Нет ограничения общего времени ответа. Суммарно до 47 сек через fallback chain.
- **Фикс:** Добавить `timeoutIntervalForResource`.
- **Статус:** TODO

### iOS-14. MEDIUM: tunnel?.reasserting не на main thread
- **Файл:** `ExtensionPlatformInterface.swift:262-263`
- **Проблема:** `pathUpdateHandler` вызывается на `.global(qos: .utility)`, а `reasserting` — UI property.
- **Фикс:** Dispatch на main queue.
- **Статус:** TODO

### iOS-15. MEDIUM: File I/O на main thread в DebugLogsView
- **Файл:** `AppShellView.swift:69-70`
- **Проблема:** Чтение логов до 512KB синхронно — UI freeze.
- **Фикс:** Вынести в async Task.
- **Статус:** TODO

### ADM-05. MEDIUM: Cookie без SameSite
- **Файл:** `admin/sidebar.tsx:86`
- **Фикс:** Добавить `SameSite=Strict`.
- **Статус:** TODO

### ADM-06. MEDIUM: Нет валидации форм
- **Файл:** `admin/src/pages/settings.tsx`
- **Фикс:** Добавить клиентскую валидацию для JSON, URL, числовых полей.
- **Статус:** TODO

### iOS-16. LOW: API ошибки захардкожены на русском
- **Файл:** `APIClient.swift:14-20`
- **Фикс:** Вынести в локализацию (Localizable.strings).
- **Статус:** TODO

### iOS-17. LOW: Мёртвый код hasDnsOutbound
- **Файл:** `AppState.swift:89,95`
- **Проблема:** `hasDnsOutbound = false` — всегда false, бесполезен в условии.
- **Фикс:** Удалить переменную, упростить условие.
- **Статус:** TODO

### iOS-18. LOW: sharedDefaults может быть nil без логирования
- **Файл:** `ConfigStore.swift`
- **Фикс:** Добавить warning лог если App Group не настроена.
- **Статус:** TODO

---

## Чеклист по фазам

### Фаза 0 — Сегодня (5 задач) — ВЫПОЛНЕНО 2026-04-11
- [x] SRV-01: Включить ufw на DE
- [x] SRV-02: PermitRootLogin prohibit-password на NL
- [x] SRV-03: Починить cron бэкапов на DE
- [x] SRV-04: Починить cron и создать backup dir на NL
- [x] SRV-05: Закрыть порт 8000 на обоих серверах

### Фаза 1 — Эта неделя (9 задач)
- [ ] BE-01: Верификация Apple покупок (Server API v2)
- [x] BE-02: Reject cluster запросы без secret (2026-04-11)
- [x] BE-03: JWT на mobile config endpoint + проверка subscription expiry (2026-04-11)
- [x] iOS-01: Фикс чёрного экрана (2026-04-11)
- [x] iOS-02: Фикс VPN автовключения (2026-04-11)
- [x] iOS-03: Фикс timer leak — переписан на TimelineView (2026-04-11)
- [x] INF-01: N/A — install.sh не существует, deploy.sh безопасен (2026-04-11)
- [x] INF-02: Документировано что DB на localhost, SSL не нужен (2026-04-11)
- [x] SRV-06: fail2ban установлен на DE и NL (2026-04-11)

### Фаза 2 — Следующая неделя (16 задач) — ВЫПОЛНЕНО 2026-04-11 (кроме серверных)
- [x] BE-04: Subscription expiry — уже сделано в BE-03
- [x] BE-05: Admin-only extend subscription
- [x] BE-06: One-time mobile refresh tokens (Redis blacklist)
- [x] BE-07: Rate limit на /sub/:token
- [x] iOS-04: Force unwraps → guard let
- [x] iOS-05: iter.next()! → guard let
- [x] iOS-06: @MainActor на CommandClientWrapper
- [x] iOS-07: deinit с removeObserver в AppState
- [x] iOS-08: backgroundTask с cancel перед новым
- [x] iOS-09: Логирование ошибок в VPNManager
- [x] iOS-10: InsecureDelegate задокументирован
- [x] ADM-01: Credentials masked
- [x] ADM-02: Server errors sanitized
- [x] ADM-03: CSRF protection (X-Requested-With)
- [x] ADM-04: providerUrl strict validation
- [x] INF-03: CSP для admin SPA
- [x] INF-04: Docker socket documented
- [x] INF-05: Resource limits на всех контейнерах
- [ ] SRV-07: Docker prune (SSH needed)
- [ ] SRV-08: Log rotation (SSH needed)
- [ ] SRV-09: SSL cert DE (Cloudflare check)
- [ ] SRV-10: SPB Relay investigation

### Фаза 3 — Через 2 недели (18 задач)
- [ ] Средние и низкие проблемы (BE-08..11, iOS-11..18, ADM-05..06, SRV-11..13)

---

## Заметки

- **Apple subscription verification (BE-01)** — обязательно до релиза в App Store
- **SPB Relay (SRV-10)** — требует отдельного расследования конфигурации relay
- **NL RAM (SRV-11)** — мониторить, upgrade при необходимости
- **SSL cert DE (SRV-09)** — дедлайн 21 мая 2026
