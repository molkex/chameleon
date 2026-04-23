# Chameleon Infra Audit — Findings и план исправлений

Дата: 2026-04-22  
Область: `backend-go` + конфиги/скрипты деплоя + wiki/документация  
Формат: только практичные пункты "что найдено" и "что исправить"

## CRITICAL

### 1) Эскалация прав в admin API
**Что найдено:** роли `operator/viewer` проходят middleware на admin-роуты, а чувствительные handlers (`CreateAdmin`, `DeleteAdmin`, `GetServerCredentials`) не проверяют `role=admin`.  
**Где:** `backend-go/internal/api/admin/routes.go`, `backend-go/internal/api/admin/admins.go`, `backend-go/internal/api/admin/nodes.go`  
**Что исправить:**
1. Добавить явную проверку `claims.Role == "admin"` в этих handlers.
2. Вынести общий middleware `RequireSuperAdmin` для критичных admin операций.
3. Добавить API-тесты: `operator/viewer` должны получать `403`.

### 2) TLS-модель небезопасна (origin/peer трафик в plaintext)
**Что найдено:** origin слушает только `80`, а cluster peers ходят по `http://...:8000`; при Cloudflare Flexible это plaintext между edge и origin.  
**Где:** `backend-go/nginx.conf`, `backend-go/deploy.sh`  
**Что исправить:**
1. Перейти на Cloudflare `Full (strict)`.
2. Поднять HTTPS на origin (Origin Certificate + nginx 443).
3. Перевести peer sync на `https://` или private network (WireGuard/VPC).
4. Ограничить доступ к `:8000` firewall-правилами.

### 3) Docker socket проброшен в backend контейнер
**Что найдено:** в `chameleon` смонтирован `/var/run/docker.sock` (RW).  
**Где:** `backend-go/docker-compose.yml`  
**Что исправить:**
1. Убрать mount docker.sock из app-контейнера.
2. Управление `singbox` вынести в отдельный root-owned helper/systemd unit.
3. Добавить hardening для контейнера: non-root, read-only FS, seccomp/capability minimization.

### 4) В репозитории найден plaintext SSH пароль
**Что найдено:** в wiki есть `sshpass -p "..."`.  
**Где:** `wiki/TROUBLESHOOTING.md`, `wiki/server-setup.html`  
**Что исправить:**
1. Немедленно ротировать все связанные пароли/ключи.
2. Удалить секрет из git history (`git-filter-repo`/BFG).
3. Добавить secret-scanning в CI (`gitleaks`/`trufflehog`).
4. Удалить практику `sshpass`, оставить только SSH keys.

## HIGH

### 5) Apple renewals: риск недокредитования продлений
**Что найдено:** идемпотентность платежей на `(source, charge_id)`, а для Apple используется `originalTransactionId` (один и тот же для renewals).  
**Где:** `backend-go/internal/api/mobile/subscription.go`, `backend-go/internal/api/mobile/subscription_notification.go`, `backend-go/migrations/003_payments.sql`  
**Что исправить:**
1. Использовать `transactionId` как `charge_id` в ledger.
2. `originalTransactionId` оставить как linkage key (для связи подписки).
3. Добавить интеграционный тест на два renewal события подряд.

### 6) Возможный обход CF/nginx до backend напрямую
**Что найдено:** `network_mode: host` + backend bind на `0.0.0.0:8000` может быть доступен снаружи при слабом firewall.  
**Где:** `backend-go/docker-compose.yml`, `backend-go/config.production.yaml`  
**Что исправить:**
1. Предпочтительно bind backend на `127.0.0.1`.
2. Если нужен внешний `:8000` для peers — strict allowlist только IP peer-нод.
3. Запретить публичный доступ на `:8000`.

### 7) Политика приватности не совпадает с фактическим удалением аккаунта
**Что найдено:** `DeleteAccount` не удаляет часть PII (например `apple_id`, `email`, history fields), хотя политика формулирует "полное удаление".  
**Где:** `backend-go/internal/db/users.go`, `backend-go/landing/privacy.html`  
**Что исправить:**
1. Ввести явный режим `erasure` (анонимизация/удаление PII).
2. Отдельно документировать минимально-необходимое retention для финансового/аудитного учета.
3. Обновить privacy/terms, чтобы текст точно соответствовал реализации.

### 8) Бэкапы не шифруются, но в политике заявлено обратное
**Что найдено:** `pg_dump | gzip` без шифрования, при этом в privacy указано, что бэкапы шифруются.  
**Где:** `backend-go/scripts/db-backup.sh`, `backend-go/landing/privacy.html`  
**Что исправить:**
1. Шифровать backup-файлы (`age`/`gpg`) до записи и перед offsite.
2. Хранить ключи отдельно от backup storage.
3. Регулярно тестировать restore и фиксировать runbook.

## MEDIUM

### 9) Утечка subscription token в request логах
**Что найдено:** логируется полный `req.URL.Path`, включая `/sub/:token`.  
**Где:** `backend-go/internal/api/server.go`  
**Что исправить:**
1. Маскировать секретные сегменты пути (`/sub/***`).
2. Либо отключить логирование legacy subscription endpoint.

### 10) `/health` раскрывает внутренние ошибки зависимостей
**Что найдено:** в response попадают тексты ошибок DB/Redis.  
**Где:** `backend-go/internal/api/server.go`  
**Что исправить:**
1. Во внешний ответ отдавать только `status`.
2. Детали ошибок оставить только в internal логах.

### 11) Runtime image запускается от root
**Что найдено:** в Dockerfile нет `USER`.  
**Где:** `backend-go/Dockerfile`, `backend-go/Dockerfile.prebuilt`  
**Что исправить:**
1. Создать non-root пользователя.
2. Перевести контейнер на non-root execution.

### 12) Миграции применяются "best effort" без трекинга версий
**Что найдено:** deploy применяет `0xx_*.sql` на каждый релиз, stderr подавляется.  
**Где:** `backend-go/deploy.sh`  
**Что исправить:**
1. Внедрить систему миграций с таблицей версий (`goose`/`migrate`/`tern`).
2. Убрать подавление ошибок и сделать fail-fast.

### 13) Файл с Telegram alert secrets создается world-readable
**Что найдено:** `/etc/chameleon-alerts.env` получает `chmod 644`.  
**Где:** `backend-go/deploy.sh`  
**Что исправить:**
1. Поставить `chmod 600`, owner `root:root`.
2. Проверить, что сервису чтение достаточно через root.

### 14) Нет явной retention-политики для `traffic_snapshots`
**Что найдено:** записи накапливаются, purge job в коде/миграциях не найден.  
**Где:** `backend-go/cmd/chameleon/main.go`, `backend-go/migrations/init.sql`  
**Что исправить:**
1. Добавить cron/job на удаление старых snapshots.
2. Зафиксировать retention срок в документации/политике.

### 15) Supply-chain: grpc версия с package-level vuln
**Что найдено:** `govulncheck` показал `GO-2026-4762` для `google.golang.org/grpc@v1.76.0` (символьной достижимости в коде не найдено).  
**Где:** результат `govulncheck -show verbose ./...`  
**Что исправить:**
1. Обновить `google.golang.org/grpc` до фиксированной версии (`>= v1.79.3`).
2. Прогнать тесты/compatibility check после обновления.

## Отдельно проверено (OK)

### Apple audience list (пустая строка не работает как wildcard)
**Что найдено:** пустые `bundleID` фильтруются, проверка аудитории идет по точному совпадению в whitelist.  
**Где:** `backend-go/internal/auth/apple.go`  
**Статус:** ОК.

## Что исправлять в первую очередь (до платного запуска)

1. RBAC фикс в admin API.
2. Убрать plaintext credential из git history + ротация.
3. Перейти на TLS strict (origin + peer).
4. Удалить docker.sock из backend контейнера.
5. Исправить ledger-идемпотентность Apple renewals.

## Runtime-проверки (нужно выполнить на серверах)

Для окончательного подтверждения статуса infra:
1. `docker compose ps`
2. `docker logs chameleon --tail 200`
3. `docker logs chameleon-nginx --tail 200`
4. `sudo ss -tlnp`
5. `sudo ufw status` и/или `sudo iptables -L -n`
6. `openssl s_client -connect madfrog.online:443 -servername madfrog.online </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates`
7. `curl -sI https://madfrog.online/api/mobile/auth/apple -X OPTIONS`
