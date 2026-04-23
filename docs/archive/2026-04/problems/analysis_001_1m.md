# Анализ iOS приложения Chameleon — #001 (1M context)

**Дата:** 2026-04-11
**Модель:** Claude Opus 4.6 (1M context)
**Проверено файлов:** 22 Swift файла в apple/

---

## Критические баги

### 1. Чёрный экран при запуске без WiFi

**Файлы:** `ChameleonApp.swift:14-15`, `AppState.swift:62-67`

**Проблема:** Пока `isInitialized == false`, приложение показывает `Color.black.ignoresSafeArea()`. Флаг `isInitialized = true` ставится только ПОСЛЕ завершения `silentConfigUpdate()`, который делает сетевые запросы.

**Цепочка:** `silentConfigUpdate()` → `fetchAndSaveConfig()` → `dataWithFallback()` пробует 3 URL последовательно:
- Primary: таймаут 30 сек (`fetchConfig` переопределяет `timeoutInterval = 30`)
- Russian relay: 7 сек
- Direct IP: 10 сек
- Плюс retry с `Task.sleep(2)` + повторный полный цикл

**Время чёрного экрана без сети: до ~96 секунд**

**Решение:** Поставить `isInitialized = true` ДО сетевых вызовов, обновление конфига вынести в фоновый Task.

---

### 2. VPN автоматически включается после отключения в Настройках iPhone

**Файлы:** `VPNManager.swift:43-47, 66-72, 124`

**Проблема:** При подключении включается On Demand с правилом `NEOnDemandRuleConnect()` ("всегда переподключать"). Когда пользователь выключает VPN через Настройки iOS:
1. iOS вызывает `stopVPNTunnel()` напрямую
2. Метод `disconnect()` приложения НЕ вызывается
3. On Demand остаётся `enabled = true` в preferences
4. iOS видит: VPN отключён + правило "всегда подключать" → автоматически переподключает

Дополнительно: в `disconnect()` есть race condition — `saveToPreferences` (async) не успевает завершиться до `stopVPNTunnel()`.

**Решение:** Отслеживать в `handleStatus()` отключение не из приложения → выключать On Demand. Добавить флаг `userInitiatedDisconnect`.

---

### 3. Утечка памяти — Timer в TimerView не останавливается

**Файл:** `MainView.swift:229-249`

```swift
let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
```

Таймер создаётся при инициализации struct, но нигде не отменяется при удалении View. Каждое пересоздание View = новый таймер, старые продолжают тикать в фоне.

**Решение:** Добавить `.onDisappear { timer.upstream.connect().cancel() }` или переписать на `TimelineView`.

---

### 4. Race condition — конкурентное обновление конфига

**Файл:** `AppState.swift:186-215`

`refreshConfig()` использует `withTaskGroup` — `silentConfigUpdate()` модифицирует `servers` массив пока UI его читает. Нет синхронизации доступа.

**Решение:** Обновлять `servers` только на MainActor после завершения загрузки.

---

### 5. Observer leak — NotificationCenter наблюдатели не удаляются

**Файлы:** `VPNManager.swift:105-113`, `AppState.swift:375-382`

- `VPNManager.statusObserver` удаляется только в `resetProfile()`, но нет `deinit`
- `AppState.statusObserver` — аналогично, нет `deinit` для очистки

**Решение:** Добавить `deinit` с удалением observer или перейти на async `NotificationCenter.notifications(named:)`.

---

### 6. Блокировка потока в PacketTunnel — `runBlocking` с семафором

**Файлы:** `ExtensionPlatformInterface.swift:44-46`, `RunBlocking.swift`

`DispatchSemaphore.wait()` полностью блокирует поток extension callback'а. Если `openTunAsync` задерживается — extension может быть убит системой по таймауту.

---

## Высокий приоритет

### 7. Force unwrap в APIClient — crash при невалидном URL

**Файл:** `APIClient.swift` — строки 102, 131, 167, 172, 205, 227

```swift
let url = URL(string: "\(AppConstants.baseURL)/api/mobile/auth/register")!  // crash если невалидный URL
var request = URLRequest(url: components.url!)  // crash если components.url == nil
```

6 мест с force unwrap при создании URL. Если `baseURL` содержит невалидные символы — crash.

**Решение:** Заменить на `guard let url = ... else { throw APIError.networkError("Invalid URL") }`.

---

### 8. Force unwrap в ExtensionPlatformInterface — итерация по IP

**Файл:** `ExtensionPlatformInterface.swift:181-184, 202-205`

```swift
while iter.hasNext() {
    let prefix = iter.next()!  // crash если next() вернёт nil
}
```

Если `hasNext()` вернёт true, но `next()` вернёт nil (несогласованность API libbox) — crash.

**Решение:** `guard let prefix = iter.next() else { break }`.

---

### 9. Thread safety в CommandClientWrapper

**Файл:** `CommandClient.swift:35-36`

```swift
fileprivate var connectionToken: UInt64 = 0
private var connectTask: Task<Void, Never>?
```

Читаются из разных потоков (MainActor и detached tasks) без синхронизации.

**Решение:** Аннотировать `@MainActor`.

---

### 10. Мёртвый код и некорректная логика ремонта конфига

**Файл:** `AppState.swift:89, 95`

```swift
let hasDnsOutbound = false  // всегда false — мёртвый код
if !hasSelector && !hasUrltest || hasDnsOutbound || hasLegacyInbound {  // hasDnsOutbound бесполезен
```

**Решение:** Убрать `hasDnsOutbound`, упростить условие.

---

## Средний приоритет

### 11. Race condition в ConfigStore — миграция при чтении

**Файл:** `ConfigStore.swift:23-44`

Getter `username` мигрирует данные из UserDefaults в Keychain при чтении. Два потока могут мигрировать одновременно → двойная запись/удаление.

---

### 12. Ошибки молча игнорируются (try?)

| Файл | Строка | Что игнорируется |
|------|--------|-----------------|
| `VPNManager.swift` | 46 | `saveToPreferences()` — On Demand не включится |
| `VPNManager.swift` | 63 | `saveToPreferences()` — On Demand не выключится |
| `VPNManager.swift` | 70 | `saveToPreferences { _ in }` — ошибка полностью проглочена |
| `ExtensionPlatformInterface.swift` | 217 | DNS fallback на 1.1.1.1 без лога |

---

### 13. Нет `timeoutIntervalForResource` в URLSession

**Файл:** `APIClient.swift:55-62`

Есть `timeoutIntervalForRequest = 5`, но нет ограничения общего времени ответа. `fetchConfig` переопределяет таймаут на 30 сек для одного запроса, а `dataWithFallback` пробует 3 URL → суммарно до 47 секунд.

---

### 14. `tunnel?.reasserting` меняется не на main thread

**Файл:** `ExtensionPlatformInterface.swift:262-263`

`pathUpdateHandler` вызывается на `DispatchQueue.global(qos: .utility)`, но `tunnel?.reasserting` — свойство UI/state.

---

## Низкий приоритет

### 15. API ошибки захардкожены на русском

**Файл:** `APIClient.swift:14-20`

```swift
case .invalidCode: return "Неверный код активации"
case .networkError(let msg): return "Ошибка сети: \(msg)"
```

Нет локализации — английские пользователи увидят русский текст.

---

### 16. JSON parsing в DebugLogsView без валидации типов

Не-строковые значения в JSON словаре могут дать неожиданный вывод.

---

### 17. UserDefaults (`sharedDefaults`) может быть nil без логирования

**Файл:** `ConfigStore.swift`

Если App Group не настроена — `sharedDefaults` тихо nil, все операции пропускаются.

---

## Сводная таблица

| # | Серьёзность | Категория | Файл | Описание |
|---|-------------|-----------|------|----------|
| 1 | Критическая | UX | AppState.swift | Чёрный экран до 96 сек без WiFi |
| 2 | Критическая | UX | VPNManager.swift | VPN автовключается после отключения в Настройках |
| 3 | Критическая | Memory leak | MainView.swift | Timer не останавливается при удалении View |
| 4 | Критическая | Race condition | AppState.swift | Конкурентное обновление servers |
| 5 | Критическая | Memory leak | VPNManager/AppState | Observer'ы не удаляются (нет deinit) |
| 6 | Критическая | Blocking | RunBlocking.swift | Семафор блокирует поток extension |
| 7 | Высокая | Crash | APIClient.swift | 6 force unwrap при создании URL |
| 8 | Высокая | Crash | ExtensionPlatformInterface | Force unwrap iter.next()! |
| 9 | Высокая | Thread safety | CommandClient.swift | Нет @MainActor на shared state |
| 10 | Высокая | Dead code | AppState.swift | hasDnsOutbound всегда false |
| 11 | Средняя | Race condition | ConfigStore.swift | Миграция username при чтении |
| 12 | Средняя | Error handling | VPNManager.swift | try? проглатывает ошибки |
| 13 | Средняя | Timeout | APIClient.swift | Нет timeoutIntervalForResource |
| 14 | Средняя | Thread safety | ExtensionPlatformInterface | reasserting не на main thread |
| 15 | Низкая | Localization | APIClient.swift | Русский текст без i18n |
| 16 | Низкая | Validation | DebugLogsView.swift | JSON без проверки типов |
| 17 | Низкая | Reliability | ConfigStore.swift | sharedDefaults nil без лога |

---

## Рекомендуемый порядок исправления

1. **Чёрный экран** (#1) — поставить `isInitialized = true` до сетевых вызовов
2. **VPN автовключение** (#2) — отслеживать disconnect из Настроек, выключать On Demand
3. **Timer leak** (#3) — добавить отмену таймера
4. **Force unwraps** (#7, #8) — заменить на guard
5. **Observer cleanup** (#5) — добавить deinit
6. **Thread safety** (#9) — добавить @MainActor
7. **Молчаливые ошибки** (#12) — логировать вместо try?
8. **Мёртвый код** (#10) — удалить hasDnsOutbound
