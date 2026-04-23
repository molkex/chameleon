# Детальный анализ проекта Chameleon — #002 (1M context)

**Дата:** 2026-04-11
**Модель:** Claude Opus 4.6 (1M context)
**Охват:** Go backend, Admin frontend, iOS app, Infrastructure, серверы DE + NL

---

## Часть 1: Серверы (живая проверка)

### DE Server (162.19.242.30)

| Параметр | Значение |
|----------|----------|
| CPU | 6 cores, Intel Haswell |
| RAM | 11GB (1.1GB used, 10GB available) |
| Disk | 96GB (19GB used, 20%) |
| Uptime | 13 days |
| Docker | 5 контейнеров, все Up + healthy |
| sing-box | v1.13.6-userapi |
| DB users | 3 |
| DB size | 9.4 MB |
| Active VPN | 0 подключений |

### NL Server (194.135.38.90)

| Параметр | Значение |
|----------|----------|
| CPU | 1 core, AMD EPYC |
| RAM | 1.9GB (647MB used, swap 57MB used!) |
| Disk | 29GB (6.9GB used, 25%) |
| Uptime | 6 days |
| Docker | 5 контейнеров, все Up + healthy |
| sing-box | v1.13.6-userapi |
| DB users | 3 |
| DB size | 9.9 MB |
| Active VPN | 0 подключений |

---

### КРИТИЧЕСКИЕ проблемы серверов

#### S1. БЭКАПЫ НЕ РАБОТАЮТ НА DE!

**Cron настроен на несуществующий путь:**
```
0 3 * * * /home/ubuntu/chameleon/backend-go/scripts/db-backup.sh >> /var/log/chameleon-backup.log 2>&1
```

Скрипт `/home/ubuntu/chameleon/backend-go/scripts/db-backup.sh` **НЕ СУЩЕСТВУЕТ**.
Скрипты лежат в `/opt/chameleon/backend-go/scripts/`.

**Результат:** Бэкап-лог файл `/var/log/chameleon-backup.log` даже не создан. Папка `/var/backups/chameleon/` пуста. **На DE НЕТ НИ ОДНОГО БЭКАПА базы данных.**

**Fix:** Обновить cron на `/opt/chameleon/backend-go/scripts/db-backup.sh`

#### S2. CRON НА NL ТОЖЕ СЛОМАН

```
* * * * * /root/chameleon/backend-go/scripts/health-check.sh >> /var/log/chameleon-health.log 2>&1
0 3 * * * /root/chameleon/backend-go/scripts/db-backup.sh >> /var/log/chameleon-backup.log 2>&1
```

Директория `/root/chameleon/` **НЕ СУЩЕСТВУЕТ**. Скрипты в `/opt/chameleon/`.
Хотя бэкап на NL работает (1 файл от Apr 10 есть), health-check из `/root/...` сломан.

**Watchdog работает** — он ссылается на `/opt/chameleon/...` (правильный путь).

**Fix:** Обновить cron: `/root/chameleon/...` → `/opt/chameleon/...`

#### S3. ПОРТ 8000 ОТКРЫТ В ИНТЕРНЕТ (оба сервера)

```
LISTEN 0 4096 *:8000 *:*   # Слушает на ВСЕХ интерфейсах
```

`curl http://162.19.242.30:8000/health` → **200 OK** (извне!)
`curl http://194.135.38.90:8000/health` → **200 OK** (извне!)

Backend API доступен напрямую, минуя nginx. Это позволяет:
- Обходить rate limiting nginx
- Обходить HTTPS
- Напрямую стучать в admin API

**Fix:** Привязать chameleon к `127.0.0.1:8000` или закрыть порт файрволом.

#### S4. НЕТ ФАЙРВОЛА НА DE

```
Chain INPUT (policy ACCEPT)   ← Всё пропускается!
Chain FORWARD (policy DROP)
Chain OUTPUT (policy ACCEPT)
```

iptables INPUT policy = ACCEPT. Любой порт открыт для мира. ufw не настроен.

**Fix:** Настроить ufw: allow 22, 80, 443, 2096. Deny остальное.

---

### ВЫСОКИЙ приоритет

#### S5. Нет ротации логов (оба сервера)

`/etc/logrotate.d/chameleon` — **не существует** ни на DE, ни на NL.

Cron пишет каждую минуту в:
- `/var/log/chameleon-health.log` — на NL уже 85KB
- `/var/log/singbox-watchdog.log`
- `/var/log/chameleon-backup.log`

Docker контейнеры тоже без лимита логов. Со временем заполнят диск.

**Fix:** Создать `/etc/logrotate.d/chameleon` + настроить Docker log driver с rotation.

#### S6. Docker мусор занимает место

| Сервер | Build cache | Reclaimable images | Dangling volumes |
|--------|------------|-------------------|-----------------|
| DE | 13.59 GB | 13.86 GB (98%) | 16 шт |
| NL | 2.30 GB | 2.76 GB (95%) | 6 шт |

На DE ~27 GB мусора при 96 GB диске (28%).
На NL ~5 GB мусора при 29 GB диске (17%).

**Fix:** `docker system prune -a --volumes` (на NL уже есть cron, но только `prune -f` без `--volumes` и `--all`)

#### S7. SSL сертификат DE истекает через 40 дней

```
notBefore=Feb 20 12:07:38 2026 GMT
notAfter=May 21 13:05:09 2026 GMT
```

Certbot на DE **не установлен** (`/etc/letsencrypt/live/` пуст). Сертификат через Cloudflare.

Если Cloudflare не автообновит origin cert — сайт упадёт 21 мая.

**Fix:** Проверить тип Cloudflare SSL (Full Strict требует валидный cert). Настроить автообновление.

#### S8. Активное сканирование/зондирование VPN портов

DE singbox логи — массовые `REALITY: processed invalid connection` от IP:
- `185.247.137.x` (целая подсеть) — систематическое зондирование
- `87.236.176.x` — аналогично
- `85.239.49.28` — повторяющиеся попытки
- `185.218.0.43` (SPB relay!) — невалидные REALITY handshake

NL singbox — аналогичное зондирование:
- `45.142.154.90` — пара попыток
- `66.132.172.136` — множественные попытки
- `185.218.0.43` (SPB relay) — **handshake длительностью до 60 сек!**

**SPB Relay шлёт невалидные REALITY подключения** — это может быть:
1. Старые клиенты с неправильными ключами
2. DPI-зонды через relay
3. Проблема конфигурации relay

**Fix:** Исследовать SPB relay логи. Добавить fail2ban для повторяющихся IP.

#### S9. Nginx получает сканы уязвимостей

Ботнеты сканируют оба сервера:
- `GET /.git/config` — утечка git конфига
- `GET /vendor/phpunit/...` — PHP RCE
- `GET /solr/admin/...` — Apache Solr exploit
- `GET /cgi-bin/authLogin.cgi` — QNAP exploit
- `GET /HNAP1` — роутер exploit
- `GET /metrics` — Prometheus метрики

Nginx корректно возвращает 404, но нет бана повторных сканеров.

**Fix:** fail2ban с фильтром на типичные scan-паттерны.

---

### СРЕДНИЙ приоритет

#### S10. NL — мало RAM, swap используется

1.9 GB RAM, 647 MB used, 57 MB swap.

5 Docker контейнеров на 1 ядре и 1.9 GB — на пределе. При росте пользователей может OOM.

#### S11. Бэкапы на NL — только 1 файл

Retention = 7 дней, но найден только 1 файл (от вчера). Либо:
- Бэкапы начали работать только вчера
- Retention чистит слишком агрессивно
- Cron путь был исправлен недавно

---

## Часть 2: Go Backend

### КРИТИЧЕСКИЕ

#### B1. Верификация Apple подписки НЕ РЕАЛИЗОВАНА

**Файл:** `backend-go/internal/api/mobile/subscription.go:36-94`

Код доверяет client-provided `transaction_id` без проверки через Apple Server API v2. Комментарий в коде: `"For now, we trust the client. This MUST be replaced before production."`

**Риск:** Любой может продлить подписку без оплаты.

#### B2. Mobile refresh token'ы не блэклистятся

**Файлы:** `backend-go/internal/api/admin/auth.go:111-125` vs `mobile/auth.go:216-242`

Admin refresh token — одноразовый (блэклист через Redis). Mobile refresh token — **многоразовый** до истечения (720 часов).

**Риск:** Украденный mobile refresh token используется бесконечно.

### ВЫСОКИЙ

#### B3. Нет rate limiting на config endpoint

`GET /api/mobile/config` и `GET /sub/:token/:mode` — без rate limiting.

**Риск:** Перебор username, DDoS через тяжёлые DB запросы.

#### B4. Нет CSRF защиты

CORS с `AllowCredentials: true` + отсутствие CSRF токенов = cross-origin атаки на admin.

#### B5. Нет аудит-логов admin операций

Удаление пользователей, продление подписок, создание админов — нигде не логируется в `admin_audit_log` таблицу (которая определена в миграции, но не используется).

#### B6. SearchUsers — нет лимита длины поиска

`pattern := "%" + search + "%"` — нет ограничения длины. Длинная строка = тяжёлый ILIKE запрос.

### СРЕДНИЙ

#### B7. Хардкод SNI fallback

`clientconfig.go:32-33` — fallback SNI `"ads.adfox.ru"`. Fingerprintable.

#### B8. Goroutine leak при rehash пароля

`admin/auth.go:80-82` — `go h.rehashPassword(...)` без WaitGroup. При shutdown может не завершиться.

#### B9. Inconsistent role defaults

API создание admin без роли → `"viewer"` (молча). CLI создание → `"admin"`. Разное поведение.

#### B10. Subscription extension — нет аудита

Admin может дать 3650 дней (10 лет) без лога кто и когда это сделал.

---

## Часть 3: Admin Frontend

### ВЫСОКИЙ

#### A1. Нет CSRF токенов

`admin/src/lib/api.ts:5-11` — POST/PUT/DELETE запросы без CSRF token header.

#### A2. Raw server errors показываются пользователю

`api.ts:16` — `throw new Error(await res.text())` — внутренние ошибки сервера (стектрейсы, пути) утекают в UI.

#### A3. Провайдерские пароли отображаются в открытом виде

`nodes.tsx:478-484` — логин/пароль хостинга показываются в UI без маскировки.

#### A4. URL из user input без валидации

`nodes.tsx:385-387` — `href={providerUrl.startsWith("http") ? providerUrl : ...}` — нет защиты от `javascript:` URLs.

### СРЕДНИЙ

#### A5. Cookie без SameSite

`sidebar.tsx:86` — sidebar state cookie без `SameSite` атрибута.

#### A6. Нет клиентской валидации форм

`settings.tsx` — JSON поля, URL поля, числовые поля — без валидации перед отправкой.

---

## Часть 4: iOS App (краткое — детали в анализ_001)

### КРИТИЧЕСКИЕ
- **Чёрный экран без WiFi** — до 96 сек ожидания сети при инициализации
- **VPN автовключается** — On Demand с `NEOnDemandRuleConnect()` не выключается при disconnect из Настроек
- **Timer memory leak** — `Timer.publish` в TimerView без отмены
- **Observer leak** — NotificationCenter observers без deinit

### ВЫСОКИЕ
- 6 force unwraps в APIClient (crash)
- Force unwrap iter.next()! в ExtensionPlatformInterface
- Thread safety в CommandClientWrapper

---

## Часть 5: Infrastructure

### КРИТИЧЕСКИЕ

#### I1. Database SSL отключён

`docker-compose.yml:23` — `sslmode=disable`. Креды БД летят plaintext.

#### I2. Docker socket mount

`docker-compose.yml:21` — `/var/run/docker.sock:/var/run/docker.sock`. Если chameleon скомпрометирован — полный контроль над хостом.

#### I3. Host network mode

Контейнеры chameleon и nginx работают с `network_mode: host` — все порты контейнеров выставлены в сеть.

#### I4. Нет resource limits на контейнерах

Ни один контейнер не имеет лимитов CPU/RAM. Утечка памяти = OOM для всего сервера.

### ВЫСОКИЕ

#### I5. Бэкапы не шифруются

`db-backup.sh:19` — `pg_dump | gzip` — только сжатие, нет шифрования. Все данные пользователей в открытом виде.

#### I6. Dockerfile без non-root user

Backend и admin Docker образы запускаются от root.

#### I7. Нет HSTS preload

nginx: `Strict-Transport-Security "max-age=31536000; includeSubDomains"` — нет `preload`.

---

## Сводная таблица всех проблем

| # | Компонент | Серьёзность | Описание |
|---|-----------|-------------|----------|
| S1 | DE Server | **КРИТИЧЕСКАЯ** | Бэкапы не работают (неверный путь cron) |
| S2 | NL Server | **КРИТИЧЕСКАЯ** | Cron health-check сломан (неверный путь) |
| S3 | Оба сервера | **КРИТИЧЕСКАЯ** | Порт 8000 открыт в интернет |
| S4 | DE Server | **КРИТИЧЕСКАЯ** | Нет файрвола (iptables ACCEPT ALL) |
| S5 | Оба сервера | Высокая | Нет ротации логов |
| S6 | Оба сервера | Высокая | Docker мусор ~27GB (DE) / ~5GB (NL) |
| S7 | DE Server | Высокая | SSL cert истекает 21 мая |
| S8 | Оба сервера | Высокая | Активное зондирование VPN портов |
| S9 | Оба сервера | Средняя | Сканирование уязвимостей через nginx |
| S10 | NL Server | Средняя | RAM на пределе, swap используется |
| S11 | NL Server | Средняя | Только 1 бэкап файл |
| B1 | Backend | **КРИТИЧЕСКАЯ** | Apple подписка не верифицируется |
| B2 | Backend | Высокая | Mobile refresh tokens многоразовые |
| B3 | Backend | Высокая | Нет rate limiting на config endpoint |
| B4 | Backend | Высокая | Нет CSRF защиты |
| B5 | Backend | Высокая | Нет аудит-логов admin операций |
| B6 | Backend | Средняя | SearchUsers без лимита длины |
| B7 | Backend | Средняя | Хардкод SNI fallback |
| B8 | Backend | Средняя | Goroutine leak при rehash |
| B9 | Backend | Средняя | Inconsistent role defaults |
| B10 | Backend | Средняя | Subscription extension без аудита |
| A1 | Admin | Высокая | Нет CSRF токенов |
| A2 | Admin | Высокая | Raw server errors в UI |
| A3 | Admin | Высокая | Пароли провайдеров в открытом виде |
| A4 | Admin | Средняя | URL без валидации |
| A5 | Admin | Средняя | Cookie без SameSite |
| A6 | Admin | Низкая | Нет валидации форм |
| I1 | Infra | **КРИТИЧЕСКАЯ** | Database SSL отключён |
| I2 | Infra | **КРИТИЧЕСКАЯ** | Docker socket mount |
| I3 | Infra | Высокая | Host network mode |
| I4 | Infra | Высокая | Нет resource limits |
| I5 | Infra | Высокая | Бэкапы не шифруются |
| I6 | Infra | Средняя | Dockerfile без non-root user |
| I7 | Infra | Низкая | Нет HSTS preload |
| iOS | iOS App | **КРИТИЧЕСКАЯ** | Чёрный экран без WiFi (до 96 сек) |
| iOS | iOS App | **КРИТИЧЕСКАЯ** | VPN автовключается после отключения в Настройках |
| iOS | iOS App | **КРИТИЧЕСКАЯ** | Timer memory leak в TimerView |
| iOS | iOS App | Высокая | 6+ force unwraps = crash risk |

**Итого: 8 критических, 14 высоких, 11 средних, 2 низких = 35 проблем**

---

## Приоритетный план исправления

### Неделя 1 — Немедленно
1. **Починить cron бэкапов** на DE и NL (сменить пути, проверить что бэкап создался)
2. **Закрыть порт 8000** файрволом или биндить на 127.0.0.1
3. **Настроить ufw** на DE (allow 22, 80, 443, 2096)
4. **Почистить Docker** — `docker system prune -a` на обоих серверах

### Неделя 2 — Безопасность
5. Убрать Docker socket mount
6. Добавить resource limits на контейнеры
7. Включить database SSL
8. Настроить ротацию логов
9. Закрыть raw error exposure в admin

### Неделя 3 — iOS баги
10. Фикс чёрного экрана (isInitialized до сетевых запросов)
11. Фикс VPN автовключения (On Demand management)
12. Фикс timer leak и observer leak
13. Убрать force unwraps

### Неделя 4 — Backend
14. Rate limiting на config endpoints
15. CSRF защита
16. Mobile refresh token blacklisting
17. Аудит-логи admin операций
18. Apple subscription verification (до релиза в App Store)
