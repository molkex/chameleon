# Chameleon VPN — Troubleshooting

Лог багов и решений. Формат: дата | проблема | причина | решение.

---

## Initial migration (2026-03-27)

### Импорты `from bot.*`
**Проблема:** Все перенесённые файлы использовали `from bot.config import`, `from bot.services.*`, `from bot.database.*`
**Причина:** Код изначально был частью Telegram бот проекта
**Решение:** Рефакторинг всех импортов на `from app.*`. Config через `get_settings()` (pydantic-settings) вместо `import config` + глобальных переменных

### proxy_monitor.py зависел от aiogram Bot
**Проблема:** Функции отправки алертов использовали `bot.send_message()` (Telegram)
**Причина:** Мониторинг слал уведомления через Telegram бота
**Решение:** Заменено на logging. В будущем — webhook или push notifications

### Double router prefix (2026-03-28)
**Проблема:** Admin API эндпоинты `/admins` и `/auth` были недоступны — 404
**Причина:** Роутеры `admins.py` и `auth.py` имели полный prefix `/api/v1/admins` и `/api/v1/auth`, но включались в `admin_router` с prefix `/api/v1/admin`. Итог: `/api/v1/admin/api/v1/admins` — двойной prefix
**Решение:** Исправлены prefix на `/admins` и `/auth` соответственно. Cookie path для refresh_token обновлён на `/api/v1/admin/auth`

### Frontend-backend response format mismatch (2026-03-28)
**Проблема:** Админ панель показывала пустые страницы — данные не приходили
**Причина:** Frontend ожидал плоские массивы/объекты, а backend оборачивал в `{"users": [...]}`, `{"protocols": [...]}`, `{"nodes": [...], "total_cost": N}`, `{"settings": {...}}`
**Решение:** Обновлён frontend: users.tsx (`.users`), protocols.tsx (`.protocols`), nodes.tsx (`.nodes`), settings.tsx (`.settings`), dashboard.tsx (полная переработка под `DashboardResponse`)

### Отсутствие login страницы (2026-03-28)
**Проблема:** При 401 redirect на `/admin/login` — белый экран
**Причина:** Не было login route/компонента в SPA
**Решение:** Создан `pages/login.tsx`, добавлен route `/login` вне основного Layout (без sidebar). Redirect обновлён на `/admin/app/login`

### Auth hook wrong path (2026-03-28)
**Проблема:** `useAuth()` hook не получал данные пользователя
**Причина:** Hook вызывал `/auth/me` → `/api/v1/auth/me`, а эндпоинт `/api/v1/admin/auth/me`
**Решение:** Исправлен путь на `/admin/auth/me`

---

## Security audit fixes (2026-03-28)

### SHA-256 пароли → bcrypt
**Проблема:** Пароли хешировались через `hashlib.sha256` без соли
**Решение:** Перешли на `bcrypt`. verify_password поддерживает legacy SHA-256 хеши для обратной совместимости

### JWT использовал session secret
**Проблема:** JWT подписывался через `admin_session_secret` вместо `admin_jwt_secret`
**Решение:** `_get_jwt_secret()` теперь использует `admin_jwt_secret`

### Role default "admin" → "viewer"
**Проблема:** При отсутствии роли в сессии/JWT присваивалась роль "admin"
**Решение:** Default изменён на "viewer" (least-privilege)

### Node API key timing attack
**Проблема:** `!=` comparison для API ключа — timing-unsafe
**Решение:** Заменено на `hmac.compare_digest()`

### Exception leakage
**Проблема:** `str(e)` в 500 ответах мог содержать SQL, пути, стек-трейсы
**Решение:** Заменено на generic "Internal server error" во всех admin API endpoints

### Viewer мог удалять пользователей
**Проблема:** `delete/extend user` использовали `require_auth` (любая роль)
**Решение:** Заменено на `require_operator`

### CORS localhost fallback
**Проблема:** При пустом CORS_ORIGINS fallback на `http://localhost:5173`
**Решение:** Fallback на пустой список (блокирует все cross-origin)

### Swagger в production
**Проблема:** `/api/docs` и `/api/redoc` доступны в production
**Решение:** Отключены если `ENVIRONMENT != "production"` (default: off)

### Хардкод пароля в nginx.conf
**Проблема:** Пароль AdGuard Home в комментарии
**Решение:** Удалён

### Ещё не исправлено (инфраструктура)
- PostgreSQL/Redis открыты на 0.0.0.0 → нужен firewall или WireGuard
- Redis без пароля → добавить `--requirepass`
- Docker socket монтирован в контейнеры → нужен socket proxy
- `/sub/{token}` использует username как токен → нужен random token
- Refresh token без инвалидации → нужен blacklist в Redis

---

*Добавляй новые записи по мере обнаружения багов*
