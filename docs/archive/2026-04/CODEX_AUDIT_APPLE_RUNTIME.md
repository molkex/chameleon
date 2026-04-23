# MadFrog Apple Client Audit — Runtime Verification Addendum

Date: 2026-04-21
Repo: `apple/` targets (`Chameleon`, `PacketTunnel`, `ChameleonMac`, `PacketTunnelMac`)

## What was executed

1. Toolchain and scheme discovery:
   - `xcodebuild -version`
   - `xcodebuild -project apple/Chameleon.xcodeproj -list`
2. Build attempts:
   - macOS: `xcodebuild ... -scheme ChameleonMac -destination 'platform=macOS' build` (success)
   - iOS: multiple `xcodebuild` attempts for `Chameleon` (`generic/platform=iOS`, `-sdk iphoneos`, explicit device id) (blocked/failing due destination/platform state)
3. Runtime smoke (macOS):
   - launch built app from DerivedData
   - verify running process
   - inspect unified logs (`/usr/bin/log show`)
4. Artifact checks:
   - `codesign -d --entitlements :-` on `MadFrog.app` and `PacketTunnelMac.appex`

## Runtime findings

### [MEDIUM] iOS runtime verification is blocked by local Xcode destination/platform state
**File:** `apple/Chameleon.xcodeproj` (build context)
**Category:** debt
**Issue:** iOS destination resolution fails in current environment (`Found no destinations for the scheme 'Chameleon' and action build`; destination errors mention `iOS 26.4 is not installed`; CoreSimulator framework version mismatch 1051.49.0 vs 1051.50.0).
**Reproduction / impact:** iOS compile/run smoke and dynamic VPN tests (DNS leak/kill-switch under runtime) cannot be completed on this machine, so iOS dynamic coverage is incomplete.
**Fix:** Align Xcode + CoreSimulator + iOS platform components on host, then rerun iOS runtime suite (build, install, launch, tunnel on/off, DNS and kill-switch probes).

### [MEDIUM] Preflight probe can produce false “all servers unreachable” when network path is `other` (utun)
**File:** `apple/ChameleonVPN/Models/PingService.swift:112`, `apple/ChameleonVPN/Models/AppState.swift:372`
**Category:** crash
**Issue:** TCP preflight uses `NWParameters.tcp` with `params.prohibitedInterfaceTypes = [.other]`. Runtime logs from app launch show repeated `unsatisfied (Interface type 'other' is prohibited by parameters), interface: utun5`.
**Reproduction / impact:** if effective route/interface resolves to utun/other (e.g., parallel VPN/tunnel path), preflight can fail all probes and block connect flow with “all servers unreachable” even when servers are alive.
**Fix:** Remove blanket `.other` prohibition or downgrade preflight to advisory when path uses `.other`; alternatively retry with relaxed parameters before declaring all endpoints dead.

## Runtime checks that passed

- `ChameleonMac` and `PacketTunnelMac` build pipeline completed successfully (`BUILD SUCCEEDED`).
- macOS app from DerivedData launched and process started successfully (no immediate startup crash observed).
- Entitlements consistency check passed for App Group:
  - app: `group.com.madfrog.vpn`
  - mac tunnel extension: `group.com.madfrog.vpn`

## Notes

- This file is an addendum to the static security/compliance audit and captures only dynamic/compile-time verification outcomes from this session.
- Static high-risk findings from the prior report (transport fallback security, kill-switch semantics, primary web-paywall compliance risk, etc.) remain valid and were not invalidated by runtime checks.
