# NL Node Migration Plan — `194.135.38.90` → `147.45.252.234`

**Дата создания:** 2026-04-14
**Контекст:** перенос NL ноды chameleon на новый Timeweb VPS. На целевом хосте
сейчас крутится Shadowsocks-VPN — wipe'аем, Shadowsocks потом поднимем на нашей
chameleon-панели отдельно.

---

## Блокеры до старта

### 1. SSH доступ к `147.45.252.234`
В `~/.secrets.env` кредов нет. Нужно от пользователя:
- логин (root / ubuntu / другой)
- пароль или путь к SSH ключу
- порт SSH если не 22

После получения — сохранить в `~/.secrets.env` через скилл `save-secrets` под
именем `NL_TIMEWEB_NEW_SSH_*`.

### 2. КРИТИЧНО — OVH DE истекает 2026-04-23
- VPS: `vps-40faf1e3.vps.ovh.net` (162.19.242.30)
- `renewalType: manual`, autoRenewal выключен
- API оплату не делает, **нужна ручная оплата через ovh.com/manager**
- Если не оплатить — 23 апреля DE сервер выключится, backend ляжет, новая NL
  нода окажется без управляющего узла
- **Действие пользователя:** зайти в OVH веб-кабинет, оплатить ~€9.99
- Без этого миграция NL бессмысленна — подтвердить с пользователем что оплачено

### 3. Apple Sandbox Tester (мелкий вопрос)
В `~/.secrets.env` сейчас:
```
APPLE_SANDBOX_TESTER_EMAIL=promomakstkach@gmail.com
APPLE_SANDBOX_TESTER_PASSWORD=ppfWvY24
```
Пользователь прислал новые: `madfrog.sandbox@test.local` / `Pass3888!` / `Mad Test`.
Уточнить — это **замена** старого или **второй** тестер. Не перезаписывать
без подтверждения.

---

## План миграции

### Шаг 1. Backup Shadowsocks с целевого хоста
Цель: сохранить конфиг чтобы потом поднять Shadowsocks на нашей панели с
теми же ключами/портами и клиенты не переподключались с нуля.

```bash
# С локалки
mkdir -p ~/кодим/VPN/chameleon/backups/shadowsocks-147.45.252.234-2026-04-14
cd ~/кодим/VPN/chameleon/backups/shadowsocks-147.45.252.234-2026-04-14

# Снять всё что относится к Shadowsocks
ssh root@147.45.252.234 'tar czf - \
  /etc/shadowsocks* \
  /etc/shadowsocks-libev \
  /opt/shadowsocks* \
  /root/shadowsocks* \
  $(find / -name "docker-compose*.yml" 2>/dev/null | grep -i shadow) \
  2>/dev/null' > shadowsocks-config.tar.gz

# Список процессов/контейнеров для документации
ssh root@147.45.252.234 'docker ps -a; systemctl list-units --type=service | grep -i shadow' \
  > services-snapshot.txt

# Если есть пользователи в БД Shadowsocks — экспорт
ssh root@147.45.252.234 'find / -name "*.db" 2>/dev/null | grep -i shadow' > db-files.txt
```

Проверить что в архиве лежит то что нужно (`tar tzf shadowsocks-config.tar.gz`).

### Шаг 2. Остановить и удалить Shadowsocks
```bash
ssh root@147.45.252.234 << 'EOF'
# Контейнеры
docker ps -a --format '{{.Names}}' | grep -i shadow | xargs -r docker rm -f
docker images --format '{{.Repository}}:{{.Tag}}' | grep -i shadow | xargs -r docker rmi -f

# Systemd сервисы
for svc in $(systemctl list-units --type=service --all | grep -i shadow | awk '{print $1}'); do
  systemctl stop "$svc"
  systemctl disable "$svc"
done

# Файлы
rm -rf /etc/shadowsocks* /etc/shadowsocks-libev /opt/shadowsocks* /root/shadowsocks*

# Проверить что порты 8388, 8488 (типичные SS порты) свободны
ss -tlnp | grep -E ':(8388|8488|443|2096)'
EOF
```

### Шаг 3. Подготовить хост под chameleon
```bash
ssh root@147.45.252.234 << 'EOF'
apt-get update
apt-get install -y docker.io docker-compose-plugin curl wget rsync
systemctl enable docker
systemctl start docker

# Создать рабочую директорию
mkdir -p /opt/chameleon
EOF
```

### Шаг 4. Деплой chameleon NL ноды
NL нода = только sing-box + nginx (без backend, без postgres — backend живёт
на DE и федерируется через cluster peers).

Использовать существующий `backend-go/deploy.sh` или следовать паттерну старой
NL ноды `194.135.38.90`. Файлы для копирования:
- `backend-go/configs/singbox-node.json` (адаптировать под NL host)
- `backend-go/nginx/nl-node.conf`
- TLS сертификаты (Let's Encrypt — `certbot --standalone -d nl.chameleonvpn.app` или
  переиспользовать SNI который уже используется)

```bash
# С локалки
cd ~/кодим/VPN/chameleon/backend-go
./deploy.sh --host 147.45.252.234 --node nl --no-deps
```

**ВАЖНО:** `--no-deps` обязательно (см. memory `feedback_deploy_nodeps.md`),
иначе при рестарте chameleon контейнера убьёт sing-box.

Проверить SNI на блокировку РКН до запуска (см. CLAUDE.md правило).

### Шаг 5. Зарегистрировать новую ноду в DE Postgres
```bash
ssh ubuntu@162.19.242.30 << 'EOF'
docker exec -i chameleon-postgres psql -U chameleon -d chameleon << 'SQL'
INSERT INTO vpn_servers (name, host, port, country, type, is_active, sort_order)
VALUES ('NL Timeweb 2', '147.45.252.234', 2096, 'NL', 'vless-reality', true, 10)
ON CONFLICT (host) DO UPDATE SET
  port = EXCLUDED.port,
  is_active = EXCLUDED.is_active;
SQL
EOF
```

Также обновить cluster peers в `backend-go/deploy.sh` или в конфиге federation:
заменить `194.135.38.90` на `147.45.252.234`.

### Шаг 6. Smoke test с iPhone
1. Открыть приложение, потянуть subscription → должна прилететь новая NL нода
2. Выбрать "Нидерланды" в server picker
3. Подключиться, проверить:
   - status = connected
   - traffic идёт (открыть `whatismyip.com`, увидеть NL IP)
   - ping в server picker зелёный (<100ms)
4. Подключиться к "Россия → NL" relay — проверить что relay тоже работает
5. Снять debug log, убедиться что нет ошибок

### Шаг 7. Удалить старую NL ноду
**Только после того как новая работает и подтверждена с iPhone.**

```bash
# Деактивировать в БД сначала (на 24 часа, чтобы клиенты переключились)
ssh ubuntu@162.19.242.30 'docker exec -i chameleon-postgres psql -U chameleon -d chameleon -c "UPDATE vpn_servers SET is_active=false WHERE host='\''194.135.38.90'\''"'

# Через сутки — проверить что нет активных соединений, потом удалить VPS из Timeweb
# через веб-кабинет или API:
# CHAMELEON_NL_TIMEWEB_ID=7225509
curl -X DELETE "https://api.timeweb.cloud/api/v1/servers/7225509" \
  -H "Authorization: Bearer $TIMEWEB_API_TOKEN"

# Удалить запись из vpn_servers
ssh ubuntu@162.19.242.30 'docker exec -i chameleon-postgres psql -U chameleon -d chameleon -c "DELETE FROM vpn_servers WHERE host='\''194.135.38.90'\''"'
```

### Шаг 8. Поднять Shadowsocks обратно через нашу панель
Отдельная задача после миграции — восстановить Shadowsocks из бэкапа
`~/кодим/VPN/chameleon/backups/shadowsocks-147.45.252.234-2026-04-14/` на
управляемом chameleon-хосте (где именно — обсудить с пользователем). Это вне
скоупа этой миграции, но не забыть.

### Шаг 9. Документация
- Обновить `wiki/wiki.md` со списком серверов
- Добавить запись в `wiki/TROUBLESHOOTING.md` если попались грабли
- Обновить таблицу серверов в `.claude/CLAUDE.md` (старый IP → новый)
- Обновить memory `project_infra_status.md`
- Коммит с сообщением вида `infra: migrate NL node to new Timeweb VPS`

---

## Откат при провале

Если новая нода не поднялась или ломает клиентов:
1. В Postgres: `UPDATE vpn_servers SET is_active=true WHERE host='194.135.38.90'`
2. В Postgres: `UPDATE vpn_servers SET is_active=false WHERE host='147.45.252.234'`
3. Старая нода `194.135.38.90` пока не удалена → клиенты вернутся на неё
4. Разбираться с новым хостом без давления времени

**Не удалять старую ноду пока новая не отработала минимум сутки.**

---

## Что НЕ забыть после миграции
- [ ] OVH DE renewal (deadline 2026-04-23)
- [ ] Поднять Shadowsocks на нашей панели
- [ ] Apple Sandbox Tester — уточнить и обновить в `~/.secrets.env`
- [ ] Продолжить тестирование iOS: Russia→DE relay, Russia→NL relay, Auto
- [ ] Step 5 из iOS: Auto selector через PingService
- [ ] Step 7: UI polish (truncated server names, badge cleanup)
- [ ] Step 8: Archive → TestFlight upload

---

## Полезные ссылки и креды (из памяти)
- DE SSH: `ubuntu@162.19.242.30` (не root!)
- NL старая: Timeweb, ID 7225509
- DE OVH: `vps-40faf1e3.vps.ovh.net`, expires 2026-04-23
- Timeweb баланс: 4173.72₽ (~13 дней при текущем расходе 9740₽/мес) на 2026-04-14
- sing-box версия: 1.13 (см. правила в CLAUDE.md)
- Xray-core: 25.12.8 (НЕ v26 — несовместим с sing-box 1.13)

## Файлы которые точно понадобятся
- [backend-go/deploy.sh](../backend-go/deploy.sh)
- [backend-go/internal/vpn/clientconfig.go](../backend-go/internal/vpn/clientconfig.go)
- [.claude/CLAUDE.md](../.claude/CLAUDE.md) — таблица серверов
- [wiki/TROUBLESHOOTING.md](TROUBLESHOOTING.md)
