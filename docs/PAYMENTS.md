# Chameleon VPN — Payments (FreeKassa)

> 🤖 Mirror: [agent-readable YAML](payments.yaml) — keep in sync. Edit either, sync the other.

> Последнее обновление: 2026-04-15

Интеграция приёма оплат для iOS-приложения через FreeKassa (SBP / карта / SberPay). App Store-compliant: оплата идёт в **внешнем Safari**, а не in-app — т.е. трактуется Apple как обычный визит на сторонний сайт (аналог InConnect).

---

## 1. Контракт и поток

```
iOS WebPaywallView
  │  POST /api/mobile/payment/initiate { plan, method, email }
  ▼
chameleon backend
  │  FK /orders/create (HMAC-SHA256)
  │  возвращает { paymentId, paymentURL }
  ▼
iOS: UIApplication.shared.open(paymentURL) → внешний Safari
  │
  ▼
Пользователь платит (СБП/карта/SberPay на сайте FreeKassa)
  │
  ├──► FK webhook → POST /api/webhooks/freekassa  (MD5: shopId:amount:secret2:orderId)
  │       chameleon: payments.CreditDays(user, plan.days)
  │       отвечает "YES"
  │
  └──► Пользователь возвращается в приложение
        scenePhase → .active  ⇒  poll GET /api/mobile/payment/status/:paymentId
        если status == "completed" — UI показывает success alert
```

### PaymentID формат
`app_{planId}_{userId}_{nonce}` — идемпотентность через `UNIQUE(source, charge_id)` в `payments` таблице.

### Тарифы (`config.yaml → payments.plans`, обновлено 2026-04-15)

| ID | Дни | Цена | Badge |
|---|---:|---:|---|
| `m1`  | 30  | 229 ₽  | — |
| `m3`  | 90  | 599 ₽  | Хит |
| `m6`  | 180 | 1099 ₽ | Выгодно |
| `m12` | 365 | 1999 ₽ | Максимум |

Trial: 3 дня, выдаётся в `auth.Register` (`payments.trial.enabled`).

---

## 2. Handlers

| Endpoint | Файл | Назначение |
|---|---|---|
| `GET  /api/mobile/plans` | `internal/api/mobile/plans.go` | Список тарифов + методов оплаты |
| `POST /api/mobile/payment/initiate` | `internal/api/mobile/payment.go` | Создание заказа, возврат paymentURL |
| `GET  /api/mobile/payment/status/:paymentId` | `internal/api/mobile/payment.go` | Статус заказа (poll) |
| `POST /api/webhooks/freekassa` | `internal/api/mobile/payment_webhook.go` | FK webhook → `CreditDays` |

Пакет `internal/payments/freekassa/`:
- `client.go` — HTTP client (`/orders/create`)
- `signature.go` — HMAC-SHA256 (API), MD5 (webhook)
- `paymentid.go` — generate/parse `app_{plan}_{user}_{nonce}`
- `types.go` — request/response структуры

---

## 3. Environment variables (`.env` на DE)

```env
FREEKASSA_SHOP_ID=70139
FREEKASSA_API_KEY=...
FREEKASSA_SECRET1=...   # подпись API
FREEKASSA_SECRET2=...   # подпись webhook
```

Все 4 должны быть проброшены в `docker-compose.yml → services.chameleon.environment`. Если забыть — backend стартует, но `initiate` вернёт `500 freekassa disabled`.

---

## 4. FreeKassa настройки магазина (shop 70139)

- **Notification URL (POST)**: `https://madfrog.online/api/webhooks/freekassa`
- **Success / Fail URL**: не используются (возврат в приложение через scenePhase)
- **Методы (i)**: `44` — СБП, `36` — Карта, `43` — SberPay
- **IP whitelist** (webhook): `168.119.157.136`, `168.119.60.227`, `178.154.197.79`, `51.250.54.238` (см. `config.yaml → payments.freekassa.ip_whitelist`)
- **TestMode** — должен быть ВЫКЛЮЧЕН в ЛК FK, иначе `/orders/create` → `Payments disabled when TestMode is enabled`

### Known issues

- **`fraud_block`** — FK блокирует подозрительные паттерны (низкая сумма + повторные попытки одного user). Минимум для тестов — 20 ₽, не меньше. Повторные попытки с одной и той же суммы/email после 403 могут упираться во временную блокировку.
- **"Проверить статус" 403 из Safari** — это не баг, это FK rejecting empty POST без merchant_id. Ожидаемое поведение.
- **Safari "Выполняется проверка платежа..." висит** — FK-side, не наша проблема. Webhook уже прилетел и кредиты начислены; пользователю достаточно вернуться в приложение (scenePhase триггер опросит статус).

---

## 5. iOS (`WebPaywallView.swift`)

Ключевые правила:
- Email **обязателен** (54-ФЗ чек) — валидация на клиенте: `isEmailValid` требует один `@`, TLD ≥ 2, нет пробелов, trim whitespace.
- Кнопка "Оплатить" **визуально disabled** пока `plans пустой || selectedPlan пустой || !isEmailValid || isLoading`. Серый фон + `textSecondary` цвет.
- Динамический title: `"Введите email"` / `"Email некорректный"` / `"Оплатить"` / `"Проверить статус"`.
- `trimmedEmail` используется в `initiate()` (не raw `email`).
- Apple Pay пока НЕ добавлен — FK numeric method id не подтверждён.

### Polling
Single-poll on `scenePhase == .active`:
```swift
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active, pendingPaymentID != nil {
        Task { await pollStatus() }
    }
}
```
Никаких continuous polling loop — достаточно одного запроса при возврате в приложение (webhook обычно опережает).

---

## 6. Чеклист для deploy новой цены / тарифа

1. Отредактировать `config.yaml → payments.plans` (локально).
2. Скопировать на DE: `scp config.yaml ubuntu@162.19.242.30:/tmp/` → `sudo cp /tmp/config.yaml /opt/chameleon/backend/config.yaml` (с backup!).
3. **ВАЖНО**: не перезаписывай весь config целиком — продовый файл содержит DE-specific `cluster.node_id: de-1`, `cluster.enabled: true`, `peers`, кастомный набор `short_ids`. Либо патчь только `plans:` секцию через sed, либо мёрдж вручную.
4. `sudo docker compose up -d --no-deps chameleon` (ВСЕГДА `--no-deps`, иначе sing-box legacy контейнер получит рестарт).
5. Проверить: `curl https://madfrog.online/api/mobile/plans` — должен вернуть новые цены.
6. Healthcheck: `sudo docker ps --filter name=chameleon` → `Up X (healthy)`.

### Ловушки
- Если backend в `Restarting (1)` после рестарта + в логах `fatal: reality private key not found` — значит config перезаписали шаблонной версией без `cluster.node_id`. Reality ключи берутся из БД через `FindLocalServer(nodeID)`, и без node_id бэкенд не стартует. Восстанавливать из `config.yaml.bak-*`.
