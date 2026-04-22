# Chameleon VPN — iOS/macOS UX/UI Audit

Дата: 2026-04-22
Аудит: все view-файлы в `apple/ChameleonVPN/Views/`, `apple/Shared/`, MenuBarContent, `AppState`, `VPNManager`, `SubscriptionManager`, `OnboardingView`, `PaywallView`, `WebPaywallView`.

Цель: выявить конкретные UX/UI проблемы и gap'ы перед submission в App Store.

---

## Раздел 1 — UX/UI проблемы

Формат: `<файл>:<строки>` — проблема — фикс — приоритет.

### P0 (блокирует App Store approval или явно ломает UX)

1. **`OnboardingView.swift:55-68` — Apple Sign-In без фоллбэка, блокирует первый запуск**
   - Проблема: единственный путь входа — Sign in with Apple. Если юзер отказался, передумал, потерял Apple ID — приложение некуда. `registerDevice()` существует в `APIClient` и вызывается в `autoRegister()`, но `autoRegister` **нигде не вызывается** из UI. Пользователь застревает на onboarding.
   - Фикс: добавить кнопку "Continue without account" под Apple кнопкой, вызывающую `app.autoRegister()` (существует, но приватный — сделать `internal`). Либо явно скрыть, но тогда это одна SSO-only приложение, что ограничит аудиторию.
   - Приоритет: **P0**

2. **`PaywallView.swift` vs `WebPaywallView.swift` — отсутствует выбор, MainView вызывает только `WebPaywallView`**
   - Проблема: в `MainView.swift:65-68` и `MainViewCalm.swift:328`, `MainViewNeon.swift:379` всегда открывается `WebPaywallView` (FreeKassa/СБП для RU). `PaywallView` (StoreKit 2, в App Store-совместимый путь) **не открывается нигде**. Для не-РФ юзеров это провальная логика: они увидят СБП/карту/SberPay вместо Apple Pay. App Store Review это **отклонит** — StoreKit 2 должен быть default для покупки цифровых товаров (IAP). Web paywall допустим только как alternative для российских карт.
   - Фикс: детектировать регион (`Locale.current.region?.identifier == "RU"` или по language/storefront) и показывать StoreKit для non-RU. Или всегда показывать StoreKit и добавить "Пользователи из России — оплата картой" ссылку на WebPaywall. **Без этого — гарантированный reject.**
   - Приоритет: **P0**

3. **`PaywallView.swift:85` (localization) — `"paywall.legal"` утверждает "does not auto-renew"**
   - Проблема: текст в en/ru.lproj (`"Subscription does not auto-renew — it is a one-time purchase"`) противоречит StoreKit продуктам `com.madfrog.vpn.sub.Ndays`. Если это consumable/non-consumable — ок; если auto-renewable — reject за misleading disclosure. Нужно проверить тип продукта в App Store Connect. Если subscription — добавить "Отменить можно в App Store → Подписки" + ссылку на управление.
   - Фикс: уточнить тип продуктов в ASC. Если auto-renewable — переписать дисклеймер по шаблону Apple (Price, Period, Auto-renewal disclosure, Cancellation instructions, Privacy, Terms links). Apple требует **прямо в paywall UI**, не только в Terms.
   - Приоритет: **P0**

4. **`OnboardingView.swift` — нет объяснения зачем запрашивается VPN permission**
   - Проблема: VPN permission (`NETunnelProviderManager.saveToPreferences`) триггерится только при первом toggleVPN (`VPNManager.swift:42-49`). Юзер видит системный алерт "MadFrog Would Like to Add VPN Configurations" без контекста. Apple HIG и Review рекомендуют pre-permission priming screen.
   - Фикс: добавить промежуточный экран после Sign-In / перед первым connect: "MadFrog настраивает защищённое подключение. iOS спросит разрешение на добавление VPN-профиля — это нужно, чтобы ваш трафик шёл через зашифрованный туннель." + кнопка Continue.
   - Приоритет: **P0**

5. **`MainView.swift:38-51` — error toast в середине screen поверх CTA, непонятно как dismiss**
   - Проблема: error toast рендерится по `.padding(.top, 60)` — он покрывает область headerRow, особенно на iPhone mini / SE. `onTapGesture { app.errorMessage = nil }` есть, но не очевиден. Нет авто-dismiss таймера. Если юзер не тронет — так и висит. Нет affordance "X".
   - Фикс: добавить auto-dismiss через 5 сек (`.task { try? await Task.sleep; if !active dismiss }`), явный "X" внутри capsule, и не перекрывать header (использовать `.safeAreaInset(edge: .top)` вместо absolute padding).
   - Приоритет: **P1** (→ P0 если частая ошибка по preflight)

### P1 (заметно портит UX)

6. **`MainViewCalm.swift:17,194-207` — `heroCardColor` для `.disconnected` это `theme.surfaceElevated` (тёмно-серый), для `.connected` — лайм. Юзер первый раз открывает приложение — вся кнопка тёмная, не видно что это primary CTA.**
   - Проблема: в disconnected состоянии hero card не выглядит как "нажми сюда". Весь экран тёмный, карточка чуть светлее фона, round black circle-подсказка power icon — это визуально weak. Юзер не понимает что его первая задача.
   - Фикс: даже в disconnected использовать `theme.accent.opacity(0.85)` или как минимум outline/glow вокруг карточки. Сравни Mullvad/ProtonVPN: их big CTA всегда яркий, независимо от state.
   - Приоритет: **P1**

7. **`MainView.swift:179-320` (ServerListView) — единственная точка входа к серверам через sheet из MainView, нет direct deep link**
   - Проблема: сейчас `showServers = true` вызывается только из статистической chip "Server" (`MainViewCalm.swift:266-269`) и `serverCard` в Neon. На Calm это chip 50% ширины внизу — маленький touch target. На iPad/macOS нет keyboard shortcut.
   - Фикс: добавить явный "Change server" с chevron на home. Добавить `.keyboardShortcut("s", modifiers: [.command])` на macOS.
   - Приоритет: **P1**

8. **`MainView.swift:205-263` (ServerListView) — список не скрывает loading/empty state**
   - Проблема: если `app.servers` пустой (первый запуск, нет auth), `List` рендерится пустым с только "Auto" строкой. Нет explicit "Loading servers..." или "Sign in to see servers". `PingSkeleton` (`MainView.swift:445-455`) есть — но работает только когда уже есть страны.
   - Фикс: добавить `if directGroups.isEmpty && relayGroups.isEmpty { ContentUnavailableView(...) }`.
   - Приоритет: **P1**

9. **`MainView.swift:256-263` — `.task` делает бесконечный polling каждые 30 сек ping probe**
   - Проблема: `while !Task.isCancelled { sleep(30); probe() }` жжёт CPU и батарею даже когда пользователь просто смотрит экран. `PingService` уже делает параллельные NWConnection которые создают реальные TCP handshakes. 20 серверов × каждые 30с = 40 подключений/минуту.
   - Фикс: ограничить — 1 запуск на open view + manual refresh через toolbar. Или повысить interval до 120с.
   - Приоритет: **P1**

10. **`MainViewCalm.swift:188` — hero card `.frame(height: 280)` — hard-coded, не respect Dynamic Type**
    - Проблема: юзеры с большим текстом (accessibility L+) не увидят contents правильно, `minimumScaleFactor(0.6)` лишь частично спасает. На iPad mini в landscape height 280 съедает половину экрана.
    - Фикс: использовать `.frame(minHeight: 240, maxHeight: 320)` + `@Environment(\.dynamicTypeSize)` проверка.
    - Приоритет: **P1**

11. **`MainViewNeon.swift:24-29` — декоративный `🐸` 260pt с opacity 0.10 offset x:80,y:140 — ломается на iPad / large screens**
    - Проблема: `.offset` absolute, не адаптивен. На iPad frog уедет в угол / пропадёт. На SE — может перекрыть CTA.
    - Фикс: использовать `GeometryReader` или relative offset (`x: width * 0.2`). Или `.containerRelativeFrame`.
    - Приоритет: **P1**

12. **`MainViewNeon.swift:146-158` — Neon статус 60pt `kerning(-2)` на узких device может truncate**
    - Проблема: "RECONNECTING" в RU локали становится "ПЕРЕПОДКЛЮЧЕНИЕ…" — 60pt с kerning -2 на iPhone SE гарантированно обрезается даже с `minimumScaleFactor(0.7)`. `lineLimit(1)` — режет, выглядит ужасно.
    - Фикс: `minimumScaleFactor(0.5)` + alternate short string `.neonReconnecting = "ВОЗВРАТ"` в ru.
    - Приоритет: **P1**

13. **`SettingsView.swift` — нет AccountView быстрого доступа, закопан в Section → NavigationLink**
    - Проблема: в Settings есть раздел "Appearance", "Routing", "Account", "About", "Diagnostics". Account — одна из самых важных кнопок (logout, delete). Она в 3-м разделе.
    - Фикс: вынести Account в topmost section, с именем юзера и подпиской inline.
    - Приоритет: **P1**

14. **`SettingsView.swift:107-121` — "Debug logs" в production build доступен**
    - Проблема: `Section(L10n.Settings.sectionDiagnostics)` всегда видима. Обычному юзеру не нужно — только создаст путаницу. Apple Review такое не любит (показывают непонятный technical info).
    - Фикс: gate за `#if DEBUG` или long-press / 7-tap на версии как iOS Settings делает. Либо переименовать в "Send logs to support" и просто share-шарить, а не открывать экран с TCP/UDP probe.
    - Приоритет: **P1**

15. **`SettingsView.swift` — нет "Auto-connect on launch" / "Connect on untrusted WiFi" настройки**
    - Проблема: стандарт индустрии. На iOS NE Extension позволяет On Demand (в VPNManager уже есть `isOnDemandEnabled`, но по умолчанию `false`). На macOS — launch agent.
    - Фикс: см. раздел "Missing features".
    - Приоритет: **P1**

16. **`AccountView.swift:16-24` — username показывается raw (monospaced, middle-truncation)**
    - Проблема: anonymous usernames от `registerDevice` — длинная случайная строка типа `u_a7f3e8b1c9d...`. Юзеру бесполезно, путает. Apple Sign-In даёт нормальный email (если пользователь не скрыл).
    - Фикс: если sign-in через Apple — показать email / Full Name. Если anonymous — показать "Anonymous device" и не показывать id. Скрыть id за раскрываемой "Details".
    - Приоритет: **P1**

17. **`DebugLogsView.swift:410-472` — endpoints/IP серверов хардкожены и включают production infrastructure (162.19.242.30, 147.45.252.234, 185.218.0.43)**
    - Проблема: эти IP попадают к юзерам, их может найти любой reverser. Да, IP скрыть невозможно в VPN, но Network test экран делает их prominent. App Store Review может заметить "hardcoded IP endpoints" как странность в VPN app.
    - Фикс: gate за DEBUG build, или убрать network test из прод build entirely.
    - Приоритет: **P1**

18. **`WebPaywallView.swift:13-312` — нет StoreKit integration, всё hard-coded на RU (`Оплата`, `Закрыть`, `Быстрые сервера. Оплата по СБП, картой или SberPay`)**
    - Проблема: все строки hard-coded русским (строки 56, 60, 74, 77, 87, 90, 113, 134, 147, 194-199, 203, 205-206). Нет L10n wrapper. App Store Review non-RU reviewer не поймёт что происходит и может flag как "not translated".
    - Фикс: всё через `L10n.WebPaywall.*`. Даже если целевая аудитория RU — нужна базовая EN локализация.
    - Приоритет: **P1**

19. **`WebPaywallView.swift:55-62` — `.navigationTitle("Подписка")` и `.toolbar.Button("Закрыть")` — hard-coded RU**
    - Проблема: см. пункт 18.
    - Фикс: как выше.
    - Приоритет: **P1**

20. **`MenuBarContent.swift:64-66, 86, 97, 122-125, 131` — все строки hard-coded русским ("Отключить", "Подключить", "Открыть окно", "Выход", "Защищено", "Подключение…", "Не подключено", "Авто (быстрейший)")**
    - Проблема: не локализовано.
    - Фикс: прогнать через L10n.
    - Приоритет: **P1**

21. **`MainView.swift:225, 243-246` — hard-coded RU сервер-группы ("Прямые подключения", "Обход блокировок", "Подключение через российский сервер...")**
    - Проблема: не локализовано, в en.lproj ключей нет.
    - Фикс: L10n.Servers.sectionDirect / sectionRelay / relayFooter.
    - Приоритет: **P1**

22. **`MainView.swift:38-51` — error toast не имеет accessibility label**
    - Проблема: VoiceOver не прочитает, что произошла ошибка. Просто озвучит текст как обычный element.
    - Фикс: `.accessibilityLabel("Ошибка")` + `.accessibilityAddTraits(.isModal)`, и `UIAccessibility.post(.announcement, ...)` при появлении.
    - Приоритет: **P1**

23. **`OnboardingView.swift:74-78` — при `isLoading` показывается только ProgressView без контекста**
    - Проблема: юзер уже нажал Apple Sign-In → дальше молча крутится колёсико. Непонятно, что происходит — идёт server registration, fetching config. Если застрянет на 10 секунд (слабая сеть, offline) — юзер думает, что приложение сломалось.
    - Фикс: "Creating your account…" лейбл + timeout fallback "Taking longer than expected…".
    - Приоритет: **P1**

24. **`PaywallView.swift:78-80` — `.task { if sub.products.isEmpty { await sub.loadProducts() } }` без timeout**
    - Проблема: `loadProducts` → `Product.products(for:)` может висеть при плохой сети. Нет watchdog.
    - Фикс: `withTaskGroup` + `.seconds(15)` timeout, fallback на error state.
    - Приоритет: **P1**

25. **`MainView.swift:11-14, 55-74` — 4 sheet на одном view, все без ID**
    - Проблема: SwiftUI 4 sheet на одном ZStack — если в быстрой последовательности тапать "Server" → "Settings" → "Pay" → "Theme", iOS может проглотить второй sheet. Паттерн anti-pattern.
    - Фикс: использовать один `sheet(item:)` с enum `ActiveSheet`.
    - Приоритет: **P1**

26. **`SettingsView.swift:40-62` — RoutingMode picker с `.pickerStyle(.menu)`, а hint только для текущего выбора под Picker'ом**
    - Проблема: юзер видит "Умный" и единственный хинт — ему хочется сравнить 3 режима. Menu picker скрывает варианты.
    - Фикс: `.pickerStyle(.segmented)` или 3 selectable cards с описанием каждой. Mullvad делает именно так.
    - Приоритет: **P1**

27. **`MainViewCalm.swift:109-128` — `statusHeadline` и `statusSubtitle` меняются через `withAnimation`? Нет, только toast анимируется**
    - Проблема: `statusHeadline` меняется мгновенно при state transition. Неплавный переход disconnected → connecting → connected. Юзер хочет почувствовать "что-то происходит".
    - Фикс: `.contentTransition(.numericText())` для text или `.animation(.smooth, value: connState)` на VStack.
    - Приоритет: **P1**

28. **`MainViewNeon.swift:306-314` — `ctaBusyText` показывает "CONNECTING…" поверх кнопки, но progress indicator тот же spinner — нет прогресс-бара / этапов**
    - Проблема: 10-секундный watchdog, юзер не знает, сколько осталось. Ни одного из: "Checking servers..." → "Establishing tunnel..." → "Authenticating..." → "Done". Из-за этого иллюзия «зависло».
    - Фикс: `AppState.connectionStage: enum { preflight, tunnel, handshake }` — каждый шаг обновляет текст. Даже без настоящих stages можно fake'ить: preflight 0-2s, tunnel 2-5s, handshake 5-10s.
    - Приоритет: **P1**

29. **`WebPaywallView.swift:110-137` — email input без "paste" button, на macOS нет clear affordance**
    - Проблема: на iOS нет keyboard toolbar "Done". На macOS email field без paste hint.
    - Фикс: `.submitLabel(.done)` + `.onSubmit { … }`, или keyboard toolbar с "Paste", "Done".
    - Приоритет: **P1**

30. **`AccountView.swift:33-47` — Logout без confirmation dialog**
    - Проблема: одна неаккуратная тапа — потеряли доступ. `deleteAccount` имеет `.alert` (строка 65), а `logout` — нет.
    - Фикс: добавить confirmation `@State var showLogoutConfirm`.
    - Приоритет: **P1**

### P2 (косметика, полезно fix'ить)

31. **`MainViewCalm.swift:49-51` — `cachedBuildInfoLine` hash виден пользователю в production ("v0.1(42) cfg:a7f3e8b1")**
    - Проблема: technical internal info на главном экране. Не нужно обычному юзеру.
    - Фикс: скрыть за long-press на version в Settings (7-tap в iOS Settings стиле), или за DEBUG build.
    - Приоритет: **P2**

32. **`MainViewNeon.swift:24-29` + `MainViewCalm.swift:66` — декоративный 🐸 emoji, но app icon тоже frog. Бренд-brand ок, но emoji в ProductUI = amateurish**
    - Фикс: заменить на SVG/PDF векторный логотип, embedded asset.
    - Приоритет: **P2**

33. **`LegalView.swift:14-23` — длинный текст без структуры, `textSelection(.enabled)` но `.font(.body)` весь текст одного размера**
    - Проблема: Terms/Privacy = wall of text. Нет h1/h2/h3 выделения "1. Service", "2. Acceptable use".
    - Фикс: распарсить по newline+digit+period как heading, либо использовать AttributedString с markdown.
    - Приоритет: **P2**

34. **`DebugLogsView.swift:132-148` — log rendering через `LazyVStack + ForEach(Array(lines.enumerated()))` — `id: \.offset` не стабилен при удалении, пересоздаёт views**
    - Проблема: когда пользователь крутит — views пересоздаются. Медленно на больших логах.
    - Фикс: использовать stable id (hash строки + index).
    - Приоритет: **P2**

35. **`PaywallView.swift:122-133` — PlanCard `.onTapGesture` без haptic**
    - Проблема: тап по plan card без feedback. Другие buttons имеют haptic (`Haptics.impact` в AppState.toggleVPN).
    - Фикс: `Haptics.selection()` на изменение selectedProductID.
    - Приоритет: **P2**

36. **`MenuBarContent.swift:59-79` — connectButton без visual state "connecting"**
    - Проблема: когда `app.isLoading` — кнопка disabled, но текст всё ещё "Подключить". Нет spinner внутри menu bar button.
    - Фикс: показать spinner inline, текст → "Подключение…".
    - Приоритет: **P2**

37. **`MenuBarContent.swift:39` — `.frame(width: 260)` — узкий popover, не адаптируется к длинным server names**
    - Проблема: "🇷🇺 Russia → NL-01" truncates.
    - Фикс: `.frame(minWidth: 260, idealWidth: 280)`.
    - Приоритет: **P2**

38. **`ThemePickerView.swift:40-62` — ScrollView для 2 тем, всегда fit в экран**
    - Проблема: overkill. Плюс `ScrollView` добавляет ненужную тень/contentInset.
    - Фикс: VStack без ScrollView на compact, ScrollView — только на regular.
    - Приоритет: **P2**

39. **`MainView.swift:38-51` — error toast только один, не support multiple errors**
    - Проблема: если juser получил connect error → нажал tonight toggle → получил ещё одну ошибку — первая молча replace'ится.
    - Фикс: queue errors, показать badge "2 errors", или использовать `.alert` для критичных.
    - Приоритет: **P2**

40. **`OnboardingView.swift:82-103` — Terms/Privacy links размер font.caption2 — 11pt, ниже iOS minimum tap target (44pt)**
    - Проблема: link "Terms of Service" на onboarding очень мелкий. iOS HIG требует 44x44pt touch.
    - Фикс: `.padding(.vertical, 8)` вокруг Button чтобы hit area была 44pt.
    - Приоритет: **P2**

41. **`SettingsView.swift` — нет "Contact Support" / "Rate App" / "Share App"**
    - Проблема: стандартные action у любого VPN.
    - Фикс: Section "Support" с mailto, SKStoreReviewController, ShareLink.
    - Приоритет: **P2**

42. **`WebPaywallView.swift:140-143` — `emailBorderColor` показывается зелёным/красным, но только на невалидный ввод — нет success checkmark**
    - Проблема: визуально ок, но нет icon для ясности.
    - Фикс: добавить `Image(systemName: "checkmark.circle.fill")` справа от field при валидности.
    - Приоритет: **P2**

43. **`MainView.swift:14` — `@State showThemePicker` объявлен, но `.sheet(isPresented: $showThemePicker)` триггера toggle нигде нет из MainView**
    - Проблема: dead state variable, хотя не критично.
    - Фикс: убрать.
    - Приоритет: **P2**

44. **`MainViewCalm.swift:285-314` — `chip()` helper имеет `action: @escaping () -> Void` но в Session chip передаётся `{}` пустой и `.allowsHitTesting(false)`**
    - Проблема: workaround — button делают visually button, но hit testing отключают. Некрасиво.
    - Фикс: разделить на `InteractiveChip` и `ReadOnlyChip`.
    - Приоритет: **P2**

45. **Весь UI — нет Dynamic Type support test'а, весь fontSize хардкожен**
    - Проблема: `font(.system(size: 28, weight: .semibold))` не масштабируется с accessibility text. `font(.title2)` масштабировался бы.
    - Фикс: вместо `.system(size:)` использовать `.title3`, `.headline`, `.subheadline` где возможно.
    - Приоритет: **P2** (но важно для App Store accessibility screening)

46. **Весь UI — нет Light Mode testing**
    - Проблема: Themes — оба тёмные (Calm charcoal, Neon dark blue). Нет light mode. Если юзер заставит system light mode — ни один текст не invertнется, backgrounds остаются тёмными. Для App Store это не reject, но минус в ревью.
    - Фикс: либо добавить `.preferredColorScheme(.dark)` на WindowGroup явно (тогда light mode не доступен вовсе, но это задокументировано), либо создать light variant каждой темы.
    - Приоритет: **P2**

47. **`MainViewCalm.swift` + `MainViewNeon.swift` — дублирование structure, 90% одинакового кода**
    - Проблема: maintainability. Любое изменение (например, +live activity toggle) нужно делать в 2 местах.
    - Фикс: refactor в ViewModel с shared logic + theme-specific render helpers.
    - Приоритет: **P2**

48. **`PaywallView.swift:107-120` — header icon `shield.lefthalf.filled` — generic, не брендированный**
    - Проблема: paywall header использует SF Symbol, не логотип MadFrog.
    - Фикс: заменить на app logo asset.
    - Приоритет: **P2**

49. **`MainView.swift:208` (autoRow) — иконка `bolt.fill` для Auto, а для серверов в country view — `bolt.horizontal.fill` (Hysteria) / `network`. Inconsistent visual language**
    - Фикс: стандартизировать — `sparkles` для Auto, country flags везде, protocol text вместо icon.
    - Приоритет: **P2**

50. **iPad layout не проверен явно — `.macWindowFrame()` (ChameleonApp.swift:119-128) ставит min 440×820 для macOS, но iPad regular классически 768-1024+ width и views рендерятся как растянутый iPhone**
    - Проблема: на iPad Pro 12.9 hero card растянется на 1000+pt ширины, буквально огромная. Нет sidebar/split view.
    - Фикс: `ViewThatFits` или `.horizontalSizeClass == .regular` → use HSplitView layout.
    - Приоритет: **P2**

---

## Раздел 2 — Отсутствующие фичи (стандарт индустрии, не бонусы)

| Фича | У кого есть | Сложность | Impact |
|---|---|---|---|
| **Kill switch (visible toggle)** | Mullvad, ProtonVPN, NordVPN, Surfshark | Средняя — в NE через `includeAllNetworks = true` + `enforceRoutes`. Уже есть On Demand в `VPNManager`, но не toggled via UI. | High — один из главных selling points VPN, юзеры проверяют settings первым делом |
| **Auto-connect on untrusted Wi-Fi** | Mullvad, ProtonVPN, NordVPN | Средняя — `NEOnDemandRuleConnect` с `NEOnDemandRuleInterfaceType.wiFi` и `SSID match`. | High — must-have для travel users |
| **Auto-connect on launch** | Все | Низкая — UserDefault flag + вызов `toggleVPN()` в `ChameleonApp.init` или `initialize()` при true. | Medium — convenience, увеличивает retention |
| **Split tunneling (exclude apps)** | NordVPN, Surfshark, ExpressVPN | **Высокая** — iOS не позволяет per-app VPN exclusion без MDM/DEP. У нас есть domain-level routing через sing-box (уже 3 mode'а), но per-app — **нельзя технически на iOS**. На macOS — можно через `includeAllNetworks = false`. | Medium (impossible на iOS но ожидается юзерами, надо objясить) |
| **Custom DNS** | Mullvad, ProtonVPN | Средняя — в sing-box конфиге есть DNS block, можно позволить override через UI. | Low-Medium — для advanced users |
| **Bytes transferred / statistics** | Все | Средняя — `NEPacketTunnelFlow` считает bytes, у нас `CommandClient.urlTest` есть stats endpoint из sing-box Clash API. Сейчас не показывается. | Medium — юзеры любят числа |
| **Session duration (live)** | Все | Уже есть — `MainViewNeon.swift:42-45` рендерит `TimerView`, но в Calm — только chip. | Done в Neon, добавить в Calm — тривиально |
| **Notifications (VPN dropped / re-connected)** | ProtonVPN, Mullvad | Средняя — `UNUserNotificationCenter.request` + trigger из `handleStatus(.disconnected)`. | High — reliability signal |
| **Widget (home screen, lock screen)** | Mullvad (connection status widget), NordVPN | Средняя — WidgetKit + App Group shared UserDefaults (уже есть App Group). | High — iOS 17+ Lock Screen widget особенно важен, 1 tap connect |
| **Live Activity (Dynamic Island)** | Mullvad (в разработке), Surfshark | Средняя-Высокая — ActivityKit, показать VPN up/down прямо в Dynamic Island. | High — modern iOS, wow-factor |
| **Shortcuts / Siri integration** | Mullvad, ProtonVPN | Низкая — AppIntents для Connect/Disconnect/Switch Server. | Medium — 5% power users любят |
| **Focus Mode integration** | — (почти ни у кого) | Низкая — via AppIntent Shortcut. | Low — nice to have |
| **Apple Watch companion** | NordVPN (частично) | Высокая — отдельный target, WatchConnectivity. | Low (пока) |
| **iCloud sync settings** | — | Средняя — NSUbiquitousKeyValueStore для theme/server/routing mode. | Low-Medium |
| **Family Sharing** | — (ProtonVPN только через enterprise) | Для StoreKit 2 — `product.isFamilyShareable = true` в ASC. Низкая. | Medium — приятный unlock |
| **Referral program UI** | Mullvad (code gifts), NordVPN | Средняя — UI экран + backend (уже есть referral hints в repo?). | Medium |
| **In-app support chat** | Surfshark, ExpressVPN | Высокая — отдельный chat component, или Intercom/Helpscout embed. | Medium — снижает support load |
| **FAQ / troubleshooting in-app** | Все major | Низкая — static markdown view, ссылки на wiki. | Medium |
| **Protocol selection UI** | Все (но у нас только VLESS Reality) | Trivial — даже если один протокол, показывать "Protocol: VLESS Reality" с чуть-objяснения. | Low |
| **Multi-hop (double VPN)** | NordVPN, ProtonVPN, Surfshark | Высокая — нужен server-side chain setup. У нас уже есть relay (SPB → DE/NL), можно экспозить как "multi-hop". | Medium — marketing feature |
| **Port forwarding** | Mullvad, ProtonVPN | **Очень высокая** — server-side + UDP port exposure. Не применимо для Reality. | Low (не наш use case) |
| **Ad/tracker blocker** | NordVPN (Threat Protection), Surfshark (CleanWeb) | Низкая — sing-box уже умеет rule_set с blocklists. Можно toggle в Settings. | Medium-High |

---

## Раздел 3 — Quick wins перед submission (топ-10)

Эти штуки реально делаются за 2-6 часов каждая и сильно поднимут качество перед App Store.

1. **Локализовать WebPaywallView и MenuBarContent** (3-4 часа)
   Все hard-coded RU строки (`Оплата`, `Закрыть`, `Подписка`, `Подключить`, `Отключить`, `Защищено`...) пропустить через L10n. Без этого ревьюеры-иностранцы видят бессмыслицу. Файлы: `WebPaywallView.swift:56,60,74,77,87,90`, `MenuBarContent.swift:64-66,86,97,122-125`.

2. **Решить Paywall trick: StoreKit vs Web** (2 часа)
   Добавить detection: `if Locale.current.region?.identifier == "RU"` — WebPaywall; else StoreKit PaywallView. В `MainView.swift:65-69` и `MainViewNeon.swift:379-403`. **Критично для App Store approval.**

3. **Pre-permission screen для VPN** (2-3 часа)
   Новый экран между OnboardingView success и первым toggleVPN. "Для защиты трафика iOS спросит разрешение добавить VPN-профиль. Мы не будем отслеживать ваши данные." + Continue button. Файл: новый `VPNPermissionPrimerView.swift`, вставить в `ChameleonApp.swift:30-39`.

4. **Confirmation dialog для Logout** (30 минут)
   `AccountView.swift:33-47` — обернуть в alert как уже сделано для deleteAccount. Копируй paттерн строк 65-75.

5. **Error toast: auto-dismiss + accessibility announcement** (1 час)
   `MainView.swift:38-51` — добавить `.task(id: app.errorMessage) { try? await Task.sleep(for:.seconds(5)); app.errorMessage = nil }` + `UIAccessibility.post(.announcement, argument: error)`.

6. **Убрать build info hash с home screen** (15 минут)
   `MainViewCalm.swift:49-51` и `MainViewNeon.swift:60-64` — gate за `#if DEBUG`.

7. **Fix ServerList infinite ping polling** (30 минут)
   `MainView.swift:256-263` — убрать `while` loop, оставить one-shot probe + manual refresh button (refresh button уже есть в toolbar). Экономия батареи + предотвращение "приложение работает в фоне / warns from iOS".

8. **Нормализовать AccountView username display** (1 час)
   `AccountView.swift:16-24` — если username начинается на `u_` (anonymous ID pattern) — показать "Anonymous (trial)" вместо hex. Если Apple — показать email.

9. **Добавить "Contact Support" в Settings → About** (1 час)
   Одна строка: `Button { UIApplication.shared.open(URL(string: "mailto:support@madfrog.online?subject=App%20Support")!) }`. Copy pattern из `AccountView`.

10. **SegmentedPicker для RoutingMode + inline описания всех трёх режимов** (2 часа)
    `SettingsView.swift:40-62` — заменить `.pickerStyle(.menu)` на 3 selectable cards (как `PlanCard`), каждая с title+hint inline. Юзер видит все варианты сразу. Сильно повышает понимание fitchiness routing mode (которая — наша фича номер 1).

---

## Резюме

### Блокеры App Store (критично):

- **Paywall логика сломана**: `WebPaywallView` открывается всегда, `PaywallView` (StoreKit) мёртвый. Reject гарантирован если у product'ов IAP тип — App Store требует IAP path as default для всех non-RU storefronts.
- **Apple Sign-In без fallback**: юзер, отказавшийся от Sign-In, застревает на onboarding. Нужна "Continue anonymously" кнопка (backend endpoint `registerDevice` уже есть, просто не вызывается из UI).
- **Нет pre-permission priming** перед запросом VPN разрешения. Apple HIG просит объяснения.
- **WebPaywall + MenuBar hard-coded RU** — ревьюер увидит непонятный текст.

### Быстрые wins (измеримый эффект за день работы):

Локализовать оставшиеся hard-coded строки, правильно route'ить paywall, добавить confirm на logout, auto-dismiss error toast, убрать build hash из прода, добавить Contact Support.

### Большие gap'ы vs конкуренты:

Kill switch (visible toggle), Auto-connect on untrusted WiFi, Lock Screen widget, Live Activity, Notifications при disconnect, Shortcuts/Siri. Все делаемые на SwiftUI + AppIntents + WidgetKit + ActivityKit.

### Сильные стороны:

- Две продуманные темы (Calm / Neon) с разной композицией — редкость.
- `PingService` out-of-band probe с кэшем и skeleton loader — профессионально.
- Preflight probe + 10s watchdog + fail-fast errors — хорошая связка в `toggleVPN`.
- Haptics grounded правильно (impact/notify/selection).
- `.macSheetSize` / `.macCloseButton` / `PlatformToolbarPlacement` — чистое кросс-платформенное разделение.
- Debug logs с Claude-compatible report builder — power user feature, но стоит скрыть за DEBUG.
- RoutingMode (smart / ru-direct / full-vpn) — отличная дифференциация от общих VPN, но UI не продаёт её.
