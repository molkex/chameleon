# Chameleon VPN — Plan

> Self-hosted VPN с нативными клиентами, 8 протоколами и монетизацией через App Store.

---

## Текущее состояние (апрель 2026)

### Готово
- **Rust backend** (Axum) — 7K строк, 11 crates
- **React admin panel** — 4K строк, dashboards, RBAC
- **iOS/macOS клиент** (Swift/SwiftUI) — 7K строк, sing-box, StoreKit 2
- **8 VPN-протоколов**: VLESS Reality TCP/gRPC, VLESS WS CDN, Hysteria2, WARP+, AnyTLS, NaiveProxy, XDNS, XICMP
- **Mobile API**: auth (Apple Sign-In + device + code), config, subscription, support chat, telemetry, speedtest
- **Admin API**: users, admins, nodes, protocols, settings, stats, shield, monitor
- **Infra**: Docker, nginx, HA watchdog, one-command installer
- **Security audit**: 3 AI (Claude + Codex + Gemini), все критичные фиксы применены

### Итого: ~21K строк кода, 144 файла

---

## Фаза 1: Launch (1-2 дня)

**Цель:** первый рабочий деплой, один человек может поставить и пользоваться.

- [ ] Деплой на сервер: `install.sh` end-to-end проверка
- [ ] Запустить миграции (001 + 002 + 003)
- [ ] Проверить: backend стартует, nginx проксирует, xray работает
- [ ] Создать admin аккаунт, зайти в панель
- [ ] Создать тестового юзера, получить /sub/{token} ссылку
- [ ] Проверить ссылку в стороннем клиенте (v2rayN / Streisand / Hiddify Next)
- [ ] Проверить iOS клиент: регистрация → конфиг → подключение → интернет работает
- [ ] Написать README: "Как поставить за 5 минут"
- [ ] Push на GitHub, сделать репо public

---

## Фаза 2: Стабилизация (1 неделя)

**Цель:** 10 тестовых юзеров, основные баги пофикшены.

- [ ] Раздать /sub/ ссылки 10 людям
- [ ] Собрать фидбек: что ломается, что неудобно
- [ ] Fix баги по фидбеку
- [ ] Мониторинг: настроить Prometheus + alerts
- [ ] Let's Encrypt сертификаты (certbot)
- [ ] Backup скрипт для PostgreSQL
- [ ] Логротация (уже в docker, проверить)

---

## Фаза 3: Telegram бот (1 неделя)

**Цель:** основной канал привлечения юзеров для СНГ рынка.

- [ ] Модуль `chameleon-telegram` (уже есть crate, пустой)
- [ ] Команды: /start → регистрация, /config → ссылка подписки, /status → статус
- [ ] Inline кнопки: выбор сервера, протокола
- [ ] Реферальная система (invite link → бонус дни)
- [ ] Оплата: FreeKassa / YooKassa / крипта (USDT TRC20)
- [ ] Уведомления: истекает подписка, новый сервер, maintenance

---

## Фаза 4: Android клиент (2-3 недели)

**Цель:** покрыть 50%+ рынка которого сейчас нет.

**Варианты:**
1. **Kotlin + sing-box (libbox)** — нативный, максимум контроля
2. **Flutter + sing-box** — кроссплатформа (iOS + Android одной кодовой базой)
3. **Branded Hiddify Next** — форк готового Flutter-клиента

**Рекомендация:** вариант 3 для быстрого старта, вариант 1 для долгосрока.

- [ ] Определиться с подходом
- [ ] Базовый клиент: подключение, выбор сервера, auth
- [ ] Google Play подписки (если нативный)
- [ ] Публикация в Google Play / APK на сайт

---

## Фаза 5: Монетизация (параллельно с Фазой 3-4)

**Цель:** revenue для покрытия серверов + развития.

- [ ] iOS: StoreKit 2 подписки (уже готово в коде, опубликовать в App Store)
- [ ] Web: Stripe Checkout для десктоп/Android юзеров
- [ ] Telegram: FreeKassa / YooKassa
- [ ] Крипта: USDT TRC20/ERC20 через CryptoCloud или ручной wallet
- [ ] Landing page с ценами и download links

---

## Фаза 6: Anti-censorship (2 недели)

**Цель:** конкурентное преимущество, которого нет у Marzban/3x-ui.

- [ ] **Auto-Shield**: мониторинг доступности протоколов → автопереключение
- [ ] **Fragment**: TLS fragmentation для обхода DPI (как в Remnawave)
- [ ] **Smart Routing**: выбор relay/direct по latency в реальном времени
- [ ] **Geo-adaptive config**: разный набор протоколов для RU/IR/CN
- [ ] **AmneziaWG**: интеграция обфусцированного WireGuard

---

## Фаза 7: Growth (ongoing)

- [ ] Документация (docs site)
- [ ] Мультиязычность (EN, FA, ZH)
- [ ] Plugin system для кастомных протоколов
- [ ] Windows/Linux клиенты
- [ ] Multi-tenancy (один инстанс → несколько VPN-сервисов)
- [ ] Marketplace протоколов и серверов

---

## Метрики успеха

| Фаза | Метрика | Target |
|-------|---------|--------|
| 1 | Работающий деплой | 1 сервер |
| 2 | Активные юзеры | 10 |
| 3 | Активные юзеры | 100 |
| 4 | Платформы | iOS + Android |
| 5 | MRR | Покрытие серверов |
| 6 | Uptime при блокировках | 99%+ |
| 7 | GitHub stars | 1000+ |
