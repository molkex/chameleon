---
title: Release iOS build via CLI (no Xcode Organizer)
date: 2026-04-26
status: active
tags: [ios, release, xcodebuild, asc, playbook]
---

# iOS CLI release

End-to-end CLI flow for shipping a new MadFrogVPN iOS build to TestFlight + App Store review. **No Xcode Organizer UI needed.** First confirmed working on build 37; standard procedure since build 50.

## Prerequisites

- ASC API key: `~/private_keys/AuthKey_6HX3DA4P2Y.p8` (see [`../state/app-store.yaml`](../state/app-store.yaml)).
- Team `99W3C374T2` logged into Xcode (Apple Development cert in keychain).
- Libbox.xcframework at `clients/apple/Frameworks/` (~494 MB, git-ignored).
- `xcodegen` installed (`brew install xcodegen`).

## Per-build flow

### 1. Bump version, regenerate project

Edit `clients/apple/project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0.27"            # bump on user-facing version change
    CURRENT_PROJECT_VERSION: "90"          # bump every build, even rebuilds
```

```bash
cd clients/apple
xcodegen generate
```

### 2. Archive

```bash
xcodebuild \
  -project MadFrogVPN.xcodeproj \
  -scheme MadFrogVPN \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  -archivePath /tmp/MadFrogVPN-buildNN.xcarchive \
  archive
```

Signs with Apple Development locally (that's expected — re-signing happens at export).

### 3. Export + upload

```bash
xcodebuild -exportArchive \
  -archivePath /tmp/MadFrogVPN-buildNN.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath /tmp/MadFrogVPN-buildNN-export \
  -authenticationKeyPath ~/private_keys/AuthKey_6HX3DA4P2Y.p8 \
  -authenticationKeyID 6HX3DA4P2Y \
  -authenticationKeyIssuerID bcb0c156-fec7-4fcd-994e-fd7cc81b5242 \
  -allowProvisioningUpdates
```

Look for `** EXPORT SUCCEEDED **` and `Progress 100 %: Upload succeeded`.

### 4. Verify in ASC

```bash
JWT=$(python3 /tmp/asc_jwt.py)    # see playbooks/apple-reject-recovery.md step 1
curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=6761008632&filter%5Bversion%5D=NN&limit=1" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);b=d['data'][0]['attributes'];print(f\"{b['version']} state={b['processingState']}\")"
```

State path: `PROCESSING` → `VALID` (≤15 min). Don't proceed to attach until `VALID`.

### 5. Attach to version + submit (optional)

If TestFlight only, you're done — internal testers get the build immediately.

For App Store release, follow [`apple-reject-recovery.md`](apple-reject-recovery.md) steps 6-8 (same flow whether it's a fresh submission or recovery after reject).

## ExportOptions.plist

Already in repo at `clients/apple/ExportOptions.plist`. Don't edit per-build — it's universal:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>99W3C374T2</string>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
```

Why this works without Distribution cert in keychain:

- `signingStyle: automatic` + `-allowProvisioningUpdates` → xcodebuild calls ASC API with the auth key, downloads Distribution cert + provisioning profile temporarily, signs the IPA, uploads, discards.
- The keychain only needs Apple Development cert (which Xcode auto-provisions when team is logged in).

## Time budget

- Archive: ~2 min on M-class Mac
- Upload: ~30 sec
- ASC processing: ~5-15 min
- Build appears in TestFlight: shortly after VALID

## When this fails

- **"No matching provisioning profile"** → run `-allowProvisioningUpdates` (already in command above). If it still fails, the bundle ID lost a capability — check Apple Developer portal.
- **Upload hangs at 0%** → the API key is wrong or expired. Regenerate JWT.
- **Build VALID but doesn't show in TestFlight UI** → ASC indexing lag, refresh after 5 min.
- **Apple rejects** → see [`apple-reject-recovery.md`](apple-reject-recovery.md).
