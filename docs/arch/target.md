# Target Architecture — Chameleon / MadFrog VPN

> Составлено: 2026-04-23
> Статус: DRAFT — требует одобрения перед исполнением
> Источник: реальный read проекта (не CLAUDE.md)

## 1. Текущая структура — найденные проблемы

### Сюрпризы (требуют действия)
- `backend/chameleon` — **скомпилированный бинарник в git, 8.7 MB**
- `backend/ascinit` — **ещё один бинарник в git, 8.7 MB**
- `clients/apple/build/` — **build artifacts в git** (ModuleCache, Intermediates, Products — сотни файлов)
- `проблем/` — **папка с кириллицей в имени** (содержит AI audit reports от 2026-04-11)
- Два nginx.conf: `backend/nginx.conf` и `infrastructure/nginx/nginx.conf` — какой активен?
- Три PLAN.md: `backend/PLAN.md`, `.claude/PLAN.md`, ROADMAP.md
- `clients/apple/PacketTunnel/PacketTunnelProvider.swift` — третий файл рядом с `ExtensionProvider.swift`, не описан в CLAUDE.md

### Сироты (без модуля)
- `install.sh`, `enable-ssl.sh`, `update.sh` в корне — это инфра-скрипты

---

## 2. Целевая структура

```
chameleon/
├── README.md
├── .github/workflows/        # CI: backend.yml, ios.yml, admin.yml
│
├── backend/                  # было backend/
│   ├── cmd/{chameleon,metrics-agent,ascinit}/
│   ├── internal/             # api, auth, cluster, config, db, vpn, payments, ...
│   ├── migrations/
│   ├── scripts/
│   ├── landing/
│   ├── tests/
│   │   ├── integration/      # testcontainers PG+Redis
│   │   └── e2e/              # sing-box check на сгенерённых конфигах
│   ├── docker-compose.yml
│   ├── Dockerfile, Dockerfile.prebuilt
│   ├── deploy.sh
│   └── README.md
│
├── clients/
│   ├── clients/apple/                # было clients/apple/
│   │   ├── MadFrogApp/       # было ChameleonVPN/  (см. Open Q3 — рискованно)
│   │   ├── MacSupport/       # было ChameleonMac/
│   │   ├── PacketTunnel/, PacketTunnelMac/
│   │   ├── Shared/, Frameworks/
│   │   ├── Tests/
│   │   │   ├── UnitTests/    # XCTest
│   │   │   └── UITests/      # XCUITest
│   │   ├── scripts/fetch-libbox.sh
│   │   ├── project.yml
│   │   └── README.md
│   │
│   └── clients/admin/                # было clients/admin/  (см. Open Q4)
│       ├── src/
│       ├── tests/{unit,e2e}/
│       └── README.md
│
├── infrastructure/
│   ├── topology.yaml
│   ├── nginx/nginx.conf      # один правильный
│   ├── deploy/               # бывшие корневые скрипты
│   │   ├── install.sh
│   │   ├── enable-ssl.sh
│   │   └── update.sh
│   ├── backup.sh, restore.sh
│   └── README.md
│
└── docs/                     # было docs/  (см. Open Q1)
    ├── OPERATIONS.md         # было OPERATIONS.md
    ├── ROADMAP.md
    ├── ARCHITECTURE.md       # этот файл после принятия
    ├── TROUBLESHOOTING.md
    ├── PAYMENTS.md
    └── archive/
```

---

## 3. Migration map

| Текущее | Целевое | Действие |
|---|---|---|
| `backend/` | `backend/` | mv |
| `backend/chameleon` (binary) | — | rm + .gitignore |
| `backend/ascinit` (binary) | — | rm + .gitignore |
| `backend/PLAN.md` | `docs/archive/2026-04/PLAN_BACKEND_GO.md` | mv |
| `backend/nginx.conf` | — | rm (если не активен) |
| `clients/apple/` | `clients/clients/apple/` | mv |
| `clients/apple/ChameleonVPN/` | `clients/clients/apple/MadFrogApp/` | mv (опц.) |
| `clients/apple/ChameleonMac/` | `clients/clients/apple/MacSupport/` | mv |
| `clients/apple/build/` | — | git rm --cached + .gitignore |
| `clients/admin/` | `clients/clients/admin/` | mv |
| `install.sh` | `infrastructure/deploy/install.sh` | mv |
| `enable-ssl.sh` | `infrastructure/deploy/enable-ssl.sh` | mv |
| `update.sh` | `infrastructure/deploy/update.sh` | mv |
| `проблем/` | `docs/archive/2026-04/problems/` | mv (исправить имя) |
| `docs/` | `docs/` | mv (опц.) |
| `docs/CODEX_AUDIT_*.md` | `docs/archive/2026-04/` | mv |
| `docs/IOS_UX_REVIEW.md` | `docs/archive/2026-04/` | mv |
| `docs/ARCHITECTURE_MESH.md` | `docs/ARCHITECTURE.md` | merge с этим файлом |
| `.claude/PLAN.md` | `docs/archive/2026-04/PLAN_INITIAL.md` | mv |

---

## 4. Test strategy

### Backend (Go)
- **Unit:** `internal/*/foo_test.go`, table-driven, моки через интерфейсы. Цель **70%**.
- **Integration:** `backend/tests/integration/`, `testcontainers-go` (PG 16 + Redis 7), HTTP test server, build tag `integration`. Цель: все endpoints happy-path.
- **E2E:** `backend/tests/e2e/`, генерация sing-box конфига → `sing-box check -c <file>`. Триггер: изменения в `internal/vpn/` или `migrations/`.
- Фреймворки: `testing` + `testify` + `testcontainers-go`. Без mock-фреймворков.

### iOS/macOS (Swift)
- **Unit:** `clients/clients/apple/Tests/UnitTests/`, XCTest, моки через protocols. Цель: ConfigStore, APIClient, ConfigSanitizer, VPNErrorMapper. **60%** Models/.
- **UI:** `clients/clients/apple/Tests/UITests/`, XCUITest для onboarding/connect/disconnect. Не тестировать реальный tunnel.
- **Snapshot:** не сейчас (две темы Calm/Neon → false positives, вернуться когда дизайн стабилен).

### Admin (React)
- **Unit:** vitest + @testing-library/react, MSW для API. **60%**.
- **E2E:** Playwright для login/users/server CRUD/node sync.

### Cross-component contract
- **OpenAPI spec** в `backend/api/openapi.yaml` (генерить через swaggo/swag из Echo)
- Генерация Swift API client из spec (snimaет класс «404 на свежей установке» из ROADMAP)
- На CI: валидация spec ↔ реальный backend

### CI matrix
- `backend.yml`: lint(golangci) + unit + build
- `backend-integration.yml`: integration tests с testcontainers
- `ios.yml`: build + unit (macOS runner)
- `admin.yml`: lint + vitest + build (e2e только на main)

---

## 5. Что удалить

- `backend/chameleon` (8.7 MB бинарник)
- `backend/ascinit` (8.7 MB бинарник)
- `clients/apple/build/` (build artifacts)
- `backend/nginx.conf` ИЛИ `infrastructure/nginx/nginx.conf` (один из дублей)
- `проблем/` (после mv содержимого)
- 4 файла `docs/CODEX_AUDIT_*.md` (задачи в ROADMAP) — в архив
- `docs/IOS_UX_REVIEW.md` — в архив
- `backend/PLAN.md`, `.claude/PLAN.md` — в архив

---

## 6. Что переименовать (с риском)

### `backend/` → `backend/` — НИЗКИЙ риск
deploy.sh использует `$(cd "$(dirname "$0")" && pwd)`, не хардкодит. Нужно обновить:
- `README.md`, `CLAUDE.md` (project + global), `docs/OPERATIONS.md`
- `.claude/commands/*.md` (SSH команды)

### `clients/apple/` → `clients/clients/apple/` — НИЗКИЙ риск
Только текстовые ссылки в README/CLAUDE/deploy.sh rsync excludes. Xcode workspace — относительные пути.

### `clients/apple/ChameleonVPN/` → `clients/clients/apple/MadFrogApp/` — **ВЫСОКИЙ риск**
Сотни FileRef в `.pbxproj`. XcodeGen пересоздаст из `project.yml`, но нужен полный iOS+macOS build для валидации. **Рекомендация: пропустить** — папка видна только разработчику, не оправдывает риск.

### `docs/` → `docs/` — НИЗКИЙ риск
Массовая замена ссылок. Решение субъективное.

---

## 7. Open questions (нужны ответы ДО старта)

| # | Вопрос | Рекомендация |
|---|---|---|
| Q1 | `docs/` → `docs/`? | Да (индустриальный стандарт) |
| Q2 | `docs/OPERATIONS.md` → `docs/OPERATIONS.md`? | Да (текущее имя — тавтология) |
| Q3 | `ChameleonVPN/` → `MadFrogApp/`? | **Нет** (риск > выгода) |
| Q4 | `clients/admin/` → `clients/clients/admin/` или `tools/clients/admin/` или оставить? | `clients/clients/admin/` |
| Q5 | Какой nginx.conf активен на проде? | Проверить `docker inspect chameleon-nginx` |
| Q6 | Что такое `PacketTunnelProvider.swift`? | Прочитать файл |
| Q7 | `ascinit`, `metrics-agent` — отдельные `tools/`? | Оставить в `backend/cmd/` |
| Q8 | Когда чистить `clients/apple/build/` из git? | На Этапе A (никто не билдит) |

---

## 8. Phase plan

| Этап | Задача | Время | Риск |
|---|---|---|---|
| **A** | Чистка мусора (бинарники, build/, проблем/, аудит-доки в архив) | ~2ч | нулевой |
| **B** | Тестовая инфра (skeleton + CI .yml без integration) | ~4ч | нулевой |
| **C** | `backend/` → `backend/` | ~30мин | низкий |
| **D** | Корневые скрипты → `infrastructure/deploy/` | ~30мин | низкий |
| **E** | `docs/` → `docs/` (если Q1 = да) | ~20мин | низкий |
| **F** | `clients/apple/` → `clients/clients/apple/`, `clients/admin/` → `clients/clients/admin/` | ~1ч | средний |
| ~~G~~ | ~~`ChameleonVPN/` → `MadFrogApp/`~~ | ~1ч | высокий — **пропустить** |

Итого: **6 этапов, ~8 часов** (без G).
Каждый этап = один git commit, откатывается через `git revert`.
