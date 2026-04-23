# Детальный анализ проекта Chameleon VPN — 002 (200k контекст)

**Дата:** 2026-04-11  
**Модель:** Claude Opus 4.6 (200k контекст)  
**Охват:** iOS приложение, Go backend, Admin SPA, инфраструктура, серверы DE + NL

---

## Содержание

1. [iOS приложение](#1-ios-приложение)
2. [Go Backend](#2-go-backend)
3. [Admin SPA](#3-admin-spa)
4. [Инфраструктура и конфиги](#4-инфраструктура-и-конфиги)
5. [Серверы — DE (162.19.242.30)](#5-серверы--de)
6. [Серверы — NL (194.135.38.90)](#6-серверы--nl)
7. [Сводная таблица](#7-сводная-таблица)

---

## 1. iOS приложение

### CRITICAL

#### 1.1 Чёрный экран без WiFi (~46 секунд)
**Файл:** `AppState.swift:62-67`  
`isInitialized = true` ставится ПОСЛЕ `silentConfigUpdate()`. Без сети: 3 fallback URL × таймауты + retry = ~46с чёрного экрана для залогиненных юзеров.  
**Фикс:** `isInitialized = true` ДО сетевого вызова, `silentConfigUpdate()` в фоновом `Task`.

#### 1.2 VPN авто-включается после выключения в Настройках iOS
**Файл:** `VPNManager.swift:43-47, 124`  
`connect()` включает On Demand с `NEOnDemandRuleConnect()`. При выключении VPN через Настройки iOS, On Demand сразу запускает его обратно. `handleStatus()` при `.disconnected` НЕ отключает On Demand.  
**Фикс:** В `handleStatus()` при `.disconnected` вызывать `disableOnDemand()`.

#### 1.3 Race condition в CommandClient
**Файл:** `CommandClient.swift:88-95`  
Если `connectionToken` меняется между `connect()` и `MainActor.run` — дублирующие подключения, утечка ресурсов.

### HIGH

#### 1.4 Task leak в selectServer()
**Файл:** `AppState.swift:312`  
`Task {}` не сохраняется — может быть отменён mid-reconnect.

#### 1.5 Task leak в handleForeground()
**Файл:** `AppState.swift:74`  
Множественные `silentConfigUpdate()` при частом foreground/background.

#### 1.6 disconnect() ошибка saveToPreferences игнорируется
**Файл:** `VPNManager.swift:70`  
On Demand может не отключиться, VPN автоматически переподключится.

#### 1.7 Race condition ConfigStore: read vs write без синхронизации
**Файл:** `ConfigStore.swift:145-247`  
Параллельная запись/чтение → partial JSON → silent fail.

#### 1.8 API таймаут 5 секунд — слишком мало
**Файл:** `APIClient.swift:57`  
На медленных сетях легитимные запросы падают по таймауту.

### MEDIUM

#### 1.9 File I/O на main thread в DebugLogsView
**Файл:** `AppShellView.swift:69-70`  
Чтение логов до 512KB синхронно → UI freeze.

#### 1.10 TimerView не останавливает таймер
Timer.publish(every: 1).autoconnect() никогда не отменяется.

#### 1.11 NWPathMonitor утечка в runNetworkTest()
**Файл:** `DebugLogsView.swift:380`  
Локальная переменная деаллоцируется, handler не вызовется.

#### 1.12 Continuation может зависнуть в testTCP()
**Файл:** `DebugLogsView.swift:477-519`  
NWConnection в `.preparing` без перехода.

#### 1.13 JSON парсинг на main thread
**Файл:** `AppState.swift:329-370`  
`buildConfigWithSelector()` парсит весь конфиг каждый раз.

#### 1.14 Log truncation O(n)
**Файл:** `TunnelFileLogger.swift:53-79`  
При >512KB каждая запись перечитывает весь файл.

### SECURITY

#### 1.15 InsecureDelegate принимает ВСЕ сертификаты
**Файл:** `APIClient.swift:39-48`  
MITM уязвимость при fallback на прямой IP.

#### 1.16 KeychainHelper.save() молча теряет токены
Ошибки Keychain через `print()`, в продакшене не видны.

### LOW

#### 1.17 Захардкоженные IP в DebugLogsView
#### 1.18 Потеря выбора сервера после reconnect
#### 1.19 X-Expire=0 обнуляет подписку

---

## 2. Go Backend

### CRITICAL

#### 2.1 Нет верификации Apple покупок на сервере
**Файл:** `internal/api/mobile/subscription.go:36-94`  
```go
// TODO: Implement Apple Server API v2 verification.
// Currently this is a placeholder that trusts the client-provided transaction_id
```
Клиент может отправить любой `transaction_id` и получить любую подписку. **Полная потеря дохода.**  
**Фикс:** Реализовать верификацию через Apple StoreKit Server API v2.

#### 2.2 Cluster auth отключается при пустом secret
**Файл:** `internal/cluster/routes.go:17-34`  
```go
if secret == "" {
    return next(c) // no secret configured, allow all
}
```
Без секрета любой может push/pull пользователей, модифицировать подписки.  
**Фикс:** Reject запросы если secret не сконфигурирован.

### HIGH

#### 2.3 Viewer/Operator могут менять подписки
**Файл:** `internal/api/admin/routes.go`  
Роли "viewer" и "operator" могут вызывать extend subscription — privilege escalation.

#### 2.4 Refresh token: race condition + неполная защита
**Файл:** `internal/api/admin/auth.go:95-128`  
Только первые 32 символа используются как ключ в Redis. Mobile API вообще не имеет защиты от reuse.

#### 2.5 Нет rate limiting на /sub/:token
**Файл:** `internal/api/server.go:130-133`  
Brute-force subscription токенов без ограничений.

#### 2.6 Нет валидации device_id
**Файл:** `internal/api/mobile/auth.go:46-117`  
Нет ограничения длины → возможно memory exhaustion.

### MEDIUM

#### 2.7 Docker socket mount в compose
**Файл:** `docker-compose.yml:20-21`  
`/var/run/docker.sock:/var/run/docker.sock` — при компрометации контейнера = полный контроль хоста.

#### 2.8 Provider пароли в plaintext в БД
**Файл:** `internal/db/models.go:54-55`  
Компрометация БД = компрометация хостинг-провайдеров.

#### 2.9 Goroutine leak в rate limiter
**Файл:** `internal/api/middleware/ratelimit.go:33`  
Cleanup goroutine никогда не останавливается.

#### 2.10 Нет graceful shutdown для background goroutines
**Файл:** `cmd/chameleon/main.go:237-243`  
Потеря in-flight traffic updates при рестарте.

#### 2.11 sslmode=disable на PostgreSQL
**Файл:** `docker-compose.yml`  
Трафик DB без шифрования (ОК для localhost, но если когда-нибудь вынесут DB на другой хост — опасно).

---

## 3. Admin SPA

### CRITICAL

#### 3.1 Provider credentials отображаются в plain text
**Файл:** `admin/src/pages/nodes.tsx:478-485`  
Пароли хостинг-провайдеров видны в DOM после re-auth. Могут быть захвачены через DevTools, скриншоты, cache.  
**Фикс:** Маскировать или показывать только первые/последние 4 символа.

### HIGH

#### 3.2 Raw error messages утекают в UI
**Файл:** `admin/src/lib/api.ts:16`  
`throw new Error(await res.text())` — стек-трейсы бэкенда видны через toast.

#### 3.3 Нет CSRF токенов
Все POST/PUT/DELETE запросы только на cookie auth, без CSRF protection.

#### 3.4 Нет валидации форм перед отправкой
Порт, URL, JSON — принимают любой ввод без проверки.

#### 3.5 providerUrl без валидации в href
**Файл:** `nodes.tsx:385-386`  
Возможна инъекция `javascript:` URL.

### MEDIUM

#### 3.6 CSP отсутствует в index.html
#### 3.7 Нет npm audit в CI
#### 3.8 Auth guard при network error → logout (ложный logout при плохой сети)

---

## 4. Инфраструктура и конфиги

### CRITICAL

#### 4.1 Default admin password в install.sh
**Файл:** `install.sh:142`  
```bash
ADMIN_PASSWORD=admin123
```
Если не поменять при установке — открытый доступ к админке.

#### 4.2 CSP с 'unsafe-inline' для script-src
**Файл:** `backend-go/nginx.conf:169`  
Позволяет XSS через inline scripts.

### HIGH

#### 4.3 CORS wildcard на speed test
**Файл:** `nginx.conf:195-200`  
`Access-Control-Allow-Origin "*"` — возможен bandwidth theft/DoS.

#### 4.4 Диагностические endpoint'ы без auth
**Файл:** `nginx.conf:278-291`  
`/api/diag/` и `/api/vpntest/` открыты публично.

#### 4.5 Rate limiting: 30r/s для admin — слишком высокий
Позволяет brute-force.

#### 4.6 TLS ciphers слабые
**Файл:** `nginx.conf:159`  
`HIGH:!aNULL:!MD5` — не исключает RC4, EXPORT, eNULL.

### MEDIUM

#### 4.7 Нет log rotation для chameleon логов
Логи в `/var/log/chameleon-*.log` растут бесконечно.

#### 4.8 Бэкапы .env без шифрования
#### 4.9 Нет HttpOnly/Secure/SameSite на cookies
#### 4.10 Secrets в deploy.sh через environment variables

---

## 5. Серверы — DE (162.19.242.30)

### Статус системы
| Параметр | Значение | Оценка |
|----------|----------|--------|
| Диск | 19G/96G (20%) | OK |
| RAM | 1.1G/11G | OK |
| Load | 0.11 | OK |
| Uptime | 13 дней | OK |
| Контейнеры | 5/5 healthy | OK |
| Пользователей | 3 | OK |
| Journal | 385MB | Растёт |

### CRITICAL проблемы DE

#### 5.1 FIREWALL ОТКЛЮЧЁН (ufw inactive)
Все порты открыты наружу: 8000 (backend API), 9090 (Clash API на localhost — OK), 15380 (User API на localhost — OK).  
Но **порт 8000 полностью открыт** — прямой доступ к API мимо Nginx (без rate limiting, без security headers).  
**Фикс:** `sudo ufw enable` с правилами для 22, 80, 443, 2096.

#### 5.2 НЕТ БЭКАПОВ
- Нет backup directory
- Нет crontab вообще (!)
- Нет health-check скриптов в cron
- При потере диска = полная потеря данных (пользователи, ключи, конфиги)  
**Фикс:** Настроить db-backup.sh в crontab, rsync на внешнее хранилище.

#### 5.3 НЕТ fail2ban
SSH открыт на весь интернет без защиты от brute-force.  
**Фикс:** `apt install fail2ban`, настроить sshd jail.

### HIGH проблемы DE

#### 5.4 Docker мусор: 27GB подлежит очистке
- Images: 13.86GB reclaimable
- Build cache: 13.48GB reclaimable  
**Фикс:** `docker system prune -a --volumes` (осторожно с volumes).

#### 5.5 Нет logrotate для chameleon
Логи будут расти бесконечно.

#### 5.6 Нет SSL сертификатов на сервере
SSL терминируется на Cloudflare. Между Cloudflare и сервером — HTTP. Если Cloudflare SSL mode = "Flexible", трафик идёт открытым текстом.  
**Проверить:** Cloudflare SSL mode должен быть "Full (Strict)" с Let's Encrypt на сервере.

### Сканеры и атаки (последние 24ч DE)
- **Umai-Scanner** (104.243.43.7): пробует /api/tags, /v1/models, /queue/status, /metrics, /.well-known/mcp.json
- **visionheight.com** (16.58.56.214, 18.218.118.203): повторный скан /
- **libredtail-http** (125.20.210.182): phpunit eval-stdin.php — попытка RCE
- **45.205.1.26**: POST на /, /_next, /api, /_next/server, /app, /api/route — Next.js scan
- **72.56.108.130**: curl на /api/v1/mobile/config, /metrics, /sub/test, /api/cluster/* — целевой recon (возможно ваш IP?)
- **195.178.110.246**: /.git/config — попытка leak конфигурации
- **sing-box Reality**: invalid connections от 185.247.137.*, 87.236.176.* — зондирование VPN порта

---

## 6. Серверы — NL (194.135.38.90)

### Статус системы
| Параметр | Значение | Оценка |
|----------|----------|--------|
| Диск | 6.9G/29G (25%) | OK |
| RAM | 647M/1.9G (34%) | Тесно |
| Swap | 57M/1G used | Активен |
| Load | 0.50 (2 CPU) | OK |
| Uptime | 6 дней | OK |
| Контейнеры | 5/5 healthy | OK |
| File descriptors | 1024 | МАЛО |

### CRITICAL проблемы NL

#### 6.1 PermitRootLogin yes
SSH позволяет логин под root с паролем. При утечке пароля — полный контроль сервера.  
**Фикс:** `PermitRootLogin no` или `prohibit-password` в sshd_config, создать непривилегированного юзера.

#### 6.2 НЕТ БЭКАПОВ (директория не существует)
Crontab содержит db-backup.sh, но backup directory `/var/backups/chameleon/` не создана — бэкапы молча падают.  
**Фикс:** `mkdir -p /var/backups/chameleon && chmod 700 /var/backups/chameleon`.

#### 6.3 SPB Relay шлёт broken connections к NL
23 ошибки за 6 часов от 185.218.0.43 (SPB Relay):
```
REALITY: processed invalid connection from 185.218.0.43 — handshake 18-60 seconds!
```
Нормальный handshake < 1с. 18-60с = SPB relay пробрасывает non-VPN трафик или сканеры на NL.  
**Причина:** SPB relay (nginx stream) на порту :2098 перенаправляет ВСЁ на NL:2096 без фильтрации.  
**Фикс:** Rate limit на SPB relay или проверить что :2098 не сканируется.

### HIGH проблемы NL

#### 6.4 File descriptor limit = 1024
Для VPN сервера с множественными подключениями — слишком мало. Каждое VPN-соединение = 2+ fd.  
**Фикс:** Увеличить в `/etc/security/limits.conf` и Docker daemon.

#### 6.5 RAM на грани (34% + swap активен)
С ростом пользователей sing-box + postgres + redis могут не уложиться в 1.9GB.  
**Мониторить:** При постоянном swap usage > 100MB рассмотреть upgrade.

#### 6.6 Нет fail2ban
#### 6.7 Нет logrotate для chameleon
#### 6.8 Порт 8000 открыт в firewall (backend API — без rate limiting Nginx)

### Сканеры и атаки (последние 24ч NL)
- **Censys** (199.45.155.69): HTTP probe, /wiki
- **l9explore** (185.177.72.61): /.env, /.git/config — попытка leak secrets
- **120.241.79.66**: phpunit RCE attempts, PHP eval-stdin injection
- **Palo Alto Xpanse** (205.210.31.130): сканирование
- **45.205.1.26**: Same Next.js POST scan as on DE
- **72.56.108.130**: Same recon (metrics, config, cluster endpoints)
- **sing-box Reality**: invalid connections от 45.142.154.90, 66.132.172.136

---

## 7. Сводная таблица

### По severity

| # | Проблема | Компонент | Severity |
|---|----------|-----------|----------|
| 2.1 | Нет верификации Apple покупок | Backend | **CRITICAL** |
| 5.1 | Firewall отключён на DE | Server DE | **CRITICAL** |
| 6.1 | PermitRootLogin yes на NL | Server NL | **CRITICAL** |
| 5.2 | Нет бэкапов на DE | Server DE | **CRITICAL** |
| 6.2 | Backup dir не создана на NL | Server NL | **CRITICAL** |
| 2.2 | Cluster auth без secret = open | Backend | **CRITICAL** |
| 4.1 | Default admin password admin123 | Infra | **CRITICAL** |
| 1.1 | Чёрный экран без WiFi 46с | iOS | **CRITICAL** |
| 1.2 | VPN авто-включается из Настроек | iOS | **CRITICAL** |
| 3.1 | Provider passwords в plain text | Admin | **CRITICAL** |
| 6.3 | SPB Relay → NL broken connections | Server NL | **HIGH** |
| 5.3 | Нет fail2ban на DE | Server DE | **HIGH** |
| 6.4 | File descriptor limit 1024 на NL | Server NL | **HIGH** |
| 5.4 | Docker мусор 27GB на DE | Server DE | **HIGH** |
| 2.3 | Viewer может менять подписки | Backend | **HIGH** |
| 2.4 | Refresh token race condition | Backend | **HIGH** |
| 2.5 | Нет rate limit на /sub/:token | Backend | **HIGH** |
| 4.2 | CSP unsafe-inline | Infra | **HIGH** |
| 4.3 | CORS wildcard на speedtest | Infra | **HIGH** |
| 3.2 | Raw errors утекают в UI | Admin | **HIGH** |
| 3.3 | Нет CSRF защиты | Admin | **HIGH** |
| 1.3 | Race condition CommandClient | iOS | **HIGH** |
| 1.4 | Task leak selectServer | iOS | **HIGH** |
| 1.5 | Task leak handleForeground | iOS | **HIGH** |
| 1.6 | disconnect() ошибка игнорируется | iOS | **HIGH** |
| 1.7 | ConfigStore race condition | iOS | **HIGH** |
| 1.8 | API таймаут 5с | iOS | **HIGH** |
| 5.5 | Нет logrotate | Server DE | **MEDIUM** |
| 5.6 | Нет SSL между Cloudflare и DE | Server DE | **MEDIUM** |
| 6.5 | RAM на грани на NL | Server NL | **MEDIUM** |
| 2.7 | Docker socket mount | Backend | **MEDIUM** |
| 2.8 | Provider пароли plaintext в DB | Backend | **MEDIUM** |
| 1.9 | File I/O на main thread | iOS | **MEDIUM** |
| 1.10 | Timer не останавливается | iOS | **MEDIUM** |
| 1.15 | Нет проверки сертификатов | iOS | **SECURITY** |

### По компоненту

| Компонент | Critical | High | Medium | Low | Total |
|-----------|----------|------|--------|-----|-------|
| iOS | 2 | 6 | 6 | 3 | 17 |
| Go Backend | 2 | 4 | 5 | 0 | 11 |
| Admin SPA | 1 | 4 | 3 | 0 | 8 |
| Infrastructure | 1 | 3 | 4 | 0 | 8 |
| Server DE | 3 | 2 | 2 | 0 | 7 |
| Server NL | 3 | 3 | 1 | 0 | 7 |
| **ИТОГО** | **12** | **22** | **21** | **3** | **58** |

---

## Рекомендованный порядок фиксов

### Немедленно (сегодня)
1. **DE: включить firewall** — `sudo ufw allow 22,80,443,2096/tcp && sudo ufw enable`
2. **NL: PermitRootLogin no** — `sed -i 's/PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && systemctl restart sshd`
3. **NL: создать backup dir** — `mkdir -p /var/backups/chameleon && chmod 700 /var/backups/chameleon`
4. **DE: настроить crontab** с health-check и db-backup

### На этой неделе
5. Apple покупки — реализовать Server API v2 верификацию
6. Cluster auth — reject при пустом secret
7. iOS: чёрный экран без WiFi
8. iOS: VPN auto-reconnect из Настроек
9. fail2ban на оба сервера
10. Docker cleanup на DE (освободить ~27GB)

### На следующей неделе
11. Все HIGH из iOS (task leaks, race conditions, таймауты)
12. Admin: CSRF, input validation, error masking
13. Infra: logrotate, SSL, CSP fix
14. NL: увеличить file descriptors, мониторить RAM
