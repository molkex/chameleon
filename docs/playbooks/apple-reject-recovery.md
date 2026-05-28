---
title: Recover from an App Store Connect rejection via API (no Xcode Organizer)
date: 2026-05-28
status: active
tags: [apple, asc, ios, release, playbook]
---

# Apple reject recovery — end-to-end via ASC API

When Apple rejects a version in review, this is the fastest path from rejection email to "resubmitted with fix" — no Xcode Organizer, no clicking through ASC web UI for the routine parts.

Field-tested on 2026-05-28 for v1.0.27 build 89 → build 90 (Guideline 2.3 UIRequiredDeviceCapabilities). See [`../incidents/2026-05-28-apple-2.3-reject.md`](../incidents/2026-05-28-apple-2.3-reject.md) for the specific case.

## Prerequisites

- ASC API key on disk: `~/private_keys/AuthKey_6HX3DA4P2Y.p8` (see [`../state/app-store.yaml`](../state/app-store.yaml) for IDs).
- Code-signing setup in Xcode keychain (Apple Development cert).
- Libbox.xcframework at `clients/apple/Frameworks/` (or symlink to main repo's copy).

## Step 1 — Get a JWT for ASC API

```bash
python3 -c "
import jwt, time
from pathlib import Path
key = Path.home() / 'private_keys' / 'AuthKey_6HX3DA4P2Y.p8'
now = int(time.time())
print(jwt.encode(
    {'iss': 'bcb0c156-fec7-4fcd-994e-fd7cc81b5242',
     'iat': now, 'exp': now+1200,
     'aud': 'appstoreconnect-v1'},
    key.read_text(),
    algorithm='ES256',
    headers={'kid': '6HX3DA4P2Y', 'typ': 'JWT'}))
" > /tmp/asc.tok
```

## Step 2 — Diagnose the rejection

```bash
JWT=$(cat /tmp/asc.tok)
APP_ID=6761008632

# Find the rejected version + its review submission
curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/apps/$APP_ID/appStoreVersions?limit=3" \
  | python3 -m json.tool

curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/apps/$APP_ID/reviewSubmissions?limit=5"
```

Note the rejection details from the ASC web inbox or the email. State will be `state: UNRESOLVED_ISSUES` on the submission and `appStoreState: REJECTED` (or sometimes `PREPARE_FOR_SUBMISSION` if Apple already auto-reset it).

## Step 3 — Implement the fix

Whatever the reject is, fix it in source. Bump `CURRENT_PROJECT_VERSION` in `clients/apple/project.yml` (build number).

Verify locally with a fresh build:

```bash
cd clients/apple
rm -rf ~/Library/Developer/Xcode/DerivedData/MadFrogVPN-*
xcodegen generate
xcodebuild -project MadFrogVPN.xcodeproj -scheme MadFrogVPN \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO build
```

For Info.plist-level issues, inspect the BUILT plist (the source plist isn't always what ends up in the IPA):

```bash
APP=~/Library/Developer/Xcode/DerivedData/MadFrogVPN-*/Build/Products/Release-iphoneos/MadFrogVPN.app
plutil -convert xml1 -o - "$APP/Info.plist" | grep -A 5 UIRequiredDeviceCapabilities
```

## Step 4 — Archive + upload the new build

```bash
xcodebuild \
  -project MadFrogVPN.xcodeproj \
  -scheme MadFrogVPN \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  -archivePath /tmp/MadFrogVPN-buildNN.xcarchive \
  archive

xcodebuild -exportArchive \
  -archivePath /tmp/MadFrogVPN-buildNN.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath /tmp/MadFrogVPN-buildNN-export \
  -authenticationKeyPath ~/private_keys/AuthKey_6HX3DA4P2Y.p8 \
  -authenticationKeyID 6HX3DA4P2Y \
  -authenticationKeyIssuerID bcb0c156-fec7-4fcd-994e-fd7cc81b5242 \
  -allowProvisioningUpdates
```

Wait for `** EXPORT SUCCEEDED **`. The build appears in ASC as `processingState: PROCESSING` within seconds and `VALID` within ~5 min.

## Step 5 — Cancel the rejected submission

The rejected `reviewSubmission` blocks adding the version to a new submission. Cancel it via PATCH:

```bash
SUBMISSION_ID=<rejected_submission_id>
curl -s -X PATCH -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  "https://api.appstoreconnect.apple.com/v1/reviewSubmissions/$SUBMISSION_ID" \
  -d "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"$SUBMISSION_ID\",\"attributes\":{\"canceled\":true}}}"
```

HTTP 200 means done.

## Step 6 — Attach new build to the version

```bash
VERSION_ID=<asc_version_id>      # from state/app-store.yaml
NEW_BUILD_ID=<from_step_4_response>

# Verify build is VALID first
curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/builds/$NEW_BUILD_ID" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['attributes']['processingState'])"
# expect: VALID

# Attach
curl -s -X PATCH -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  "https://api.appstoreconnect.apple.com/v1/appStoreVersions/$VERSION_ID/relationships/build" \
  -d "{\"data\":{\"type\":\"builds\",\"id\":\"$NEW_BUILD_ID\"}}"
# expect: HTTP 204
```

## Step 7 — Submit for review

You'll need a **review submission**. If there's an empty draft already in ASC (state `READY_FOR_REVIEW` with 0 items), reuse it. Otherwise create one.

```bash
# Find existing READY_FOR_REVIEW with 0 items
curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/apps/$APP_ID/reviewSubmissions?limit=10" \
  | python3 -m json.tool | grep -B 2 READY_FOR_REVIEW

# Add the version as an item
SUBMISSION_ID=<ready_for_review_submission>
curl -s -X POST -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  "https://api.appstoreconnect.apple.com/v1/reviewSubmissionItems" \
  -d "{\"data\":{\"type\":\"reviewSubmissionItems\",\"relationships\":{
    \"appStoreVersion\":{\"data\":{\"type\":\"appStoreVersions\",\"id\":\"$VERSION_ID\"}},
    \"reviewSubmission\":{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"$SUBMISSION_ID\"}}}}}"
# expect: HTTP 201

# Submit
curl -s -X PATCH -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  "https://api.appstoreconnect.apple.com/v1/reviewSubmissions/$SUBMISSION_ID" \
  -d "{\"data\":{\"type\":\"reviewSubmissions\",\"id\":\"$SUBMISSION_ID\",\"attributes\":{\"submitted\":true}}}"
# expect: HTTP 200
```

## Step 8 — Verify

```bash
curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/appStoreVersions/$VERSION_ID" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['data']['attributes']['appStoreState'])"
# expect: WAITING_FOR_REVIEW
```

You're done. Apple will pick it up within 1-3 days for App Store Review (sometimes hours). If `releaseType: AFTER_APPROVAL`, the version auto-releases once approved.

## Common gotchas

- **HTTP 409 "Item is already present in another reviewSubmission"** — the rejected submission still holds the version. Run step 5 first.
- **HTTP 409 "Item was already submitted"** — you can't DELETE a `reviewSubmissionItem` that went through review. Cancel the parent submission instead (step 5).
- **App Privacy data types** — Apple has NO public API for this. Verify via web UI before submitting if you've added new event types. See [`../state/app-store.yaml`](../state/app-store.yaml) for current declarations.
- **Resolution Center reply** — after cancellation, the thread is read-only. Not a blocker — the new submission goes in fresh.
- **IAP first submission** — first-time IAPs are bundled with the first app version review. If the app gets rejected, IAPs silently stall in `WAITING_FOR_REVIEW`. After the app is APPROVED, resubmit each IAP standalone via `POST /v1/inAppPurchaseSubmissions`.

## When the API isn't enough

Use Chrome MCP / web UI for:

- App Privacy data type declarations (no API).
- Resolution Center text replies (no API).
- IAP screenshots upload (have API but flaky).

Everything else (versions, builds, submissions, attachments) goes via API — faster, scriptable, no clicking.
