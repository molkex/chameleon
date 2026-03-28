# Chameleon VPN — Research: VPN Applications (2026-03-27)

## Анализ open-source VPN клиентов

### 1. sing-box-for-apple (SagerNet) — 790 stars
**Reference implementation для iOS/macOS**
- Swift + SwiftUI + libbox (Go via gomobile)
- gRPC IPC: CommandServer в PacketTunnel ↔ CommandClient в host app
- `Box` orchestrator для lifecycle management
- **Auto-wake timer** (1 мин) для iOS NE suspension — КРИТИЧНО
- Profile-based: конфиги как JSON в App Groups

### 2. Hiddify — 27,900 stars
**Лучший cross-platform Flutter VPN**
- Flutter + Riverpod + sing-box (libbox)
- `CoreInterface` abstraction — UI отделён от VPN engine
- Drift (SQLite) для профилей/логов
- Multi-format subscriptions (sing-box, V2ray, Clash)
- **Минус:** Flutter на iOS = больше бинарник, не 100% нативный feel

### 3. Karing — 10,400 stars
**sing-box + Flutter + iCloud sync**
- Модифицированный sing-box core (риск — divergence от upstream)
- iCloud sync профилей между устройствами — отличный UX
- WebDAV sync как universal fallback
- tvOS поддержка

### 4. Amnezia VPN — 10,900 stars
**Multi-protocol C++ клиент**
- Abstract `VpnProtocol` base class → каждый протокол наследует
- Protocol factory pattern в VpnConnection
- macOS: unprivileged UI + privileged background service (System Extension)
- iOS: IosController → Swift bridge → Network Extension
- **Минус:** Qt/QML = declining iOS support, GPL-3.0

### 5. Outline (Google/Jigsaw) — 9,100 stars
**Composable networking SDK**
- Outline SDK: StreamDialer/PacketDialer — composable/nestable transport layers
- Separation: Client app ↔ Manager app
- **Минус:** Polymer 2.0 (outdated), Cordova (declining), Shadowsocks-only

### 6. v2rayNG — 52,850 stars
**Самый популярный (Android only)**
- Kotlin, Xray-core
- Standard VLESS URI import, QR sharing
- Latency-based server selection

---

## Patterns for Chameleon VPN

### Обязательные (Critical)
| Паттерн | Источник | Описание |
|---|---|---|
| Auto-wake timer | sing-box-for-apple | 1-min timer в PacketTunnel — без него соединения умирают |
| Two-process model | Все | Main app (UI) + PacketTunnelProvider (tunnel) — обязательно на iOS |
| gRPC IPC | sing-box-for-apple | CommandServer/CommandClient для связи app ↔ tunnel |
| @Observable | SwiftUI 2025+ | Не ObservableObject, а @Observable macro (iOS 17+) |

### Высокий приоритет
| Паттерн | Источник | Описание |
|---|---|---|
| CoreInterface abstraction | Hiddify | UI отделён от VPN engine через абстракцию |
| Abstract VpnProtocol | Amnezia | Base class для поддержки нескольких протоколов |
| Profile-as-JSON | sing-box, Hiddify | Конфиги в JSON, индексируются в локальной БД |
| Repository pattern | SwiftUI consensus | View → @Observable ViewModel → Repository → NetworkService |
| StoreKit 2 SubscriptionOfferView | Apple | Нативный UI для подписок |

### Средний приоритет
| Паттерн | Источник | Описание |
|---|---|---|
| iCloud sync | Karing | Синхронизация профилей между устройствами |
| Composable Dialers | Outline SDK | Layered transport composition |
| Multi-format import | Hiddify, Karing | V2ray/Clash/sing-box subscription links |

### Анти-паттерны (ИЗБЕГАТЬ)
1. ❌ Flutter/Cordova/Qt на iOS — non-native feel, больше бинарник
2. ❌ Modified core forks — divergence от upstream, security patches отстают
3. ❌ Monolithic VPN service — ВСЕГДА разделять UI и tunnel process
4. ❌ Hardcoded prices — ТОЛЬКО StoreKit dynamic pricing
5. ❌ Skip NE wake timers — connections silently die
6. ❌ ObservableObject — устарело, использовать @Observable macro

---

## Звёзды и стеки

| Проект | Stars | Stack | Наша оценка |
|---|---|---|---|
| v2rayNG | 52,854 | Kotlin + Xray | Android only |
| sing-box core | 31,835 | Go | Наш VPN engine |
| Hiddify | 27,897 | Flutter + sing-box | Хорошая архитектура, но Flutter |
| Amnezia | 10,898 | C++ Qt + WireGuard | Multi-protocol паттерн |
| Karing | 10,405 | Flutter + sing-box | iCloud sync идея |
| Outline | 9,099 | TypeScript + Go | SDK architecture |
| sing-box-for-apple | 790 | **Swift + sing-box** | **Reference для нас** |

**Доминантный паттерн 2026:** Native UI (Swift) + Go core (libbox) + gRPC IPC + two-process (app + PacketTunnel)

→ Это именно то, что мы строим. Наш выбор архитектуры подтверждён.
