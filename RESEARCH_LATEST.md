# Chameleon — Latest Research (2026-03-27)

## CRITICAL: Обновления за последние 3 дня

### Xray-core v26.3.27 (released 2026-03-25)
- **Finalmask** — post-transport obfuscation layer:
  - XDNS: proxy over DNS queries (last resort fallback)
  - XICMP: proxy over ICMP ping packets
  - header-custom + Sudoku: custom traffic appearance
  - fragment (TCP) + noise (UDP): packet manipulation
  - WireGuard + Finalmask = "stronger disguise than any other WG variant"
- **Native Hysteria2 inbound** — no separate hy2 binary needed
- **ECH default**: echForceQuery = "full"
- **Browser masquerading**: Chrome/Firefox/Edge UA on HTTP transports
- **BBR congestion** for XHTTP/3
- WE ARE ON v26.2.6 — MUST UPGRADE

### AmneziaWG 2.0 (released 2026-03-25)
- Signature packets mimic DNS, QUIC, SIP protocols
- Dynamic headers change continuously during session
- Ranged headers (not static values)
- Continuous obfuscation during data transmission
- Adopted by Windscribe and NymVPN
- Drop-in replacement for AWG v1.5

### sing-box 1.13 Warning
- "uTLS is NOT recommended for censorship circumvention — use NaiveProxy"
- Our REALITY configs use uTLS — vulnerability acknowledged
- NaiveProxy = actual Chromium TLS stack (unfingerprintable)
- sing-box 1.13 supports NaiveProxy outbound natively

### AnyTLS (1009 stars, growing fast)
- Defeats TLS-in-TLS fingerprinting (Aparecium attack)
- sing-box 1.12+ supports natively
- Critical because REALITY is detectable by Aparecium

### Russia TSPU 2030 Plan
- 83.7 billion rubles budget
- 954 Tbit/s throughput target (from 752.6)
- 100% of Russian traffic processed by TSPU in 2026
- ML-based classification coming

## Protocol Priority Stack (updated)

1. **VLESS Reality TCP** — primary, works now but Aparecium-detectable
2. **AnyTLS** — anti-fingerprint, defeats TLS-in-TLS detection
3. **NaiveProxy** — Chromium native TLS (unfingerprintable)
4. **VLESS CDN WS** — Cloudflare fallback (CDN too big to block)
5. **VLESS gRPC** — backup
6. **Hysteria2** — fast UDP (risk: UDP blackout)
7. **AmneziaWG 2.0** — upgraded obfuscation
8. **WARP + Finalmask** — disguised WireGuard
9. **XDNS** — emergency fallback over DNS (last resort)
10. **XICMP** — emergency fallback over ICMP (absolute last resort)
