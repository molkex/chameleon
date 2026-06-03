---
date: 2026-06-03
severity: P1 (UX — looks like account loss; no data lost)
component: apple/macOS · Keychain · ACCT-IDENTITY
status: fixed (code in tree; ships next macOS build)
related: [2026-06-01-acct-identity-demote.md, 2026-06-01-acct-identity-demote-recurrence.md]
---

# macOS "account switched to trial after update"

## Symptom
After updating the macOS app, a paying Apple user saw the onboarding /
trial screen instead of their account ("после обновления всё равно акк
сменился на трел (на маке)"). Reported on the user's own Mac.

## What actually happened — NO account was lost
Pulled live state from the user's Mac + NL. Everything agreed on the **paid**
account; nothing was demoted:

| Source | Value |
|---|---|
| Keychain (login.keychain-db, svc `com.madfrog.vpn`) | `username=device_b6f01ebb`, tokens for **user_id 12351**, refresh→2026-06-29, access refreshed 06-02 for the same user; username/refresh mdat still 05-30 ⇒ **not** rewritten ⇒ no anon re-register |
| App-group UserDefaults | `onboardingCompleted=true`, `subscriptionExpire=2026-06-15`, config refreshed today |
| NL DB users.id=12351 | `auth_provider=apple`, apple_id set, molkex@ya.ru, subscription_expiry 2026-06-15 |

Red herring in the logs: build 38d logged base `…/Library/Group Containers/…`
and build 101 logged `…/Library/GroupContainersAlias/…`. **`GroupContainersAlias`
is a system symlink → `Group Containers`** (same inode), so the app-group
container was never split. Not the cause.

## Root cause (macOS-specific)
`KeychainHelper` stored items as a plain `kSecClassGenericPassword` with **no
`kSecAttrAccessGroup` and no `kSecUseDataProtectionKeychain`**. On macOS that
lands them in the **legacy file keychain**, where `kSecAttrAccessible` is
ignored and each item's access is gated by an **ACL bound to the creating
binary's code signature / designated requirement**.

Updating from the old build (38d, dev signing) to build 101 (different
signature) ⇒ the new binary's first read failed the ACL ⇒
`SecItemCopyMatching` returned nil (or popped an unconfirmed "allow access"
prompt) ⇒ `configStore.username == nil` ⇒ root gate
`MadFrogVPNApp.swift:53` set `isAuthenticated=false` ⇒ **OnboardingView**
(the trial/sign-in screen).

`AppState.initialize()` does **not** anon-register when `username==nil`, so the
paid identity survived untouched; once keychain access was (re)granted
(Allow / relaunch) the app recovered to 12351 (access token refreshed 06-02,
config fetched today).

## Who is affected
- **Pure App-Store→App-Store updates: almost certainly NOT** — same distribution
  identity ⇒ stable designated requirement ⇒ the ACL stays valid.
- **Signing-identity changes on the same Mac** (dev/Xcode → TestFlight → App
  Store): triggers it. This incident is a dev/TestFlight artifact that exposed a
  real latent macOS gap.

## Fix (Option A, 2026-06-03)
Move keychain items to the **data-protection keychain** scoped by an explicit,
signature-independent **access group**, so macOS scopes by access group
(stable across signatures within the Team) instead of per-binary ACL — the
durability iOS already had.

- `Shared/KeychainHelper.swift`: every query now sets
  `kSecUseDataProtectionKeychain:true` + `kSecAttrAccessGroup =
  99W3C374T2.com.madfrog.vpn.keychain`. `load()` does a **seamless dual-read
  migration**: canonical location first, else the legacy/implicit location,
  copying forward + deleting the stale copy — so users signed in on a pre-fix
  build (iOS and macOS) stay logged in across the update. `delete()` clears both.
- Entitlements: added `keychain-access-groups =
  [$(AppIdentifierPrefix)com.madfrog.vpn.keychain]` to the two targets that
  actually call the keychain — **MadFrogVPN** (iOS) and **MadFrogVPNMac**.
  The PacketTunnel extensions + widget compile `KeychainHelper`/`PlatformDevice`
  but never call them (`PlatformDevice.identifier` is main-app only), so they
  intentionally get no new entitlement → minimal provisioning surface.
  Automatic signing + `-allowProvisioningUpdates` should provision Keychain
  Sharing automatically. **Watch-point at the next build cut:** if signing fails
  on `keychain-access-groups`, enable the "Keychain Sharing" capability on App
  IDs `com.madfrog.vpn` + `com.madfrog.vpn.mac` (portal / ASC API
  `POST /v1/bundleIdCapabilities`), then rebuild — same one-time caveat as the
  App Group linkage.
- Test: `KeychainHelperTests.testLoadMigratesLegacyItem` (seeds a legacy item,
  asserts `load()` migrates it forward). Skips in sim like the rest of the suite
  → on-device / build-for-testing only.

## Side gap noted (not fixed here)
12351's keychain has **no `authProvider`/`appleUserID`** markers (signed in
before those shipped, build <94) ⇒ on the Mac it is not protected by the
anti-anon-demote gate and cannot silent-Apple-reauth (needs appleUserID); only
a manual Sign in with Apple recovers. Tracked as a follow-up (backfill markers
from `/config` `auth_provider`).

## Recovery for an affected user
Already self-heals once keychain access is granted: relaunch / click "Always
Allow" on the keychain prompt / Sign in with Apple (reclaims by apple_id) or
Restore. The paid sub (→2026-06-15) is intact throughout.
