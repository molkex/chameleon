---
title: App Store Connect API checks
date: 2026-05-28
status: active
tags: [asc, ios, app-store, playbook]
---

# App Store Connect API — quick checks

When you need to verify state from ASC without poking the web UI. Covers:
1. JWT generation (used by every call below)
2. App version state (READY_FOR_SALE / WAITING_FOR_REVIEW / IN_REVIEW / etc)
3. IAP state (all 4 non-renewing subscriptions)
4. Review submissions

All IDs come from [`../state/app-store.yaml`](../state/app-store.yaml). Re-read that file before assuming product/version IDs haven't changed.

## JWT (paste into every snippet)

```bash
source ~/.secrets.env  # not strictly required — only key path matters
python3 - <<'PY'
import jwt, time, os, pathlib
key = pathlib.Path(os.path.expanduser("~/private_keys/AuthKey_6HX3DA4P2Y.p8")).read_text()
now = int(time.time())
print(jwt.encode(
    {"iss": "bcb0c156-fec7-4fcd-994e-fd7cc81b5242",
     "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
    key, algorithm="ES256",
    headers={"kid": "6HX3DA4P2Y", "typ": "JWT"}
))
PY
```

Exports to `$T` for re-use:

```bash
T=$(python3 -c '...the snippet above, returning token only...')
```

## Check live app version state

```bash
curl -s -H "Authorization: Bearer $T" \
  "https://api.appstoreconnect.apple.com/v1/apps/6761008632/appStoreVersions?limit=3" \
  | python3 -m json.tool | grep -E '"version|appStoreState|releaseType' | head -20
```

Expected for current release: `"version": "1.0.27"`, `"appStoreState": "READY_FOR_SALE"`.

## Check all 4 IAPs at once

```bash
python3 <<'PY'
import jwt, time, json, urllib.request, os, pathlib
key = pathlib.Path(os.path.expanduser("~/private_keys/AuthKey_6HX3DA4P2Y.p8")).read_text()
now = int(time.time())
token = jwt.encode(
    {"iss": "bcb0c156-fec7-4fcd-994e-fd7cc81b5242",
     "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
    key, algorithm="ES256", headers={"kid": "6HX3DA4P2Y", "typ": "JWT"})

# IDs from docs/state/app-store.yaml — keep in sync if products change.
iaps = [
    ("com.madfrog.vpn.sub.30days",  "6762097906"),
    ("com.madfrog.vpn.sub.90days",  "6762098097"),
    ("com.madfrog.vpn.sub.180days", "6762098056"),
    ("com.madfrog.vpn.sub.365days", "6762097872"),
]
print(f"{'product_id':<35} state")
for pid, aid in iaps:
    # NOTE: must be /v2/ — /v1/inAppPurchases/{id} returns 404 for IAPs created via v2.
    req = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com/v2/inAppPurchases/{aid}",
        headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.loads(r.read())["data"]["attributes"]
        print(f"{pid:<35} {data.get('state','?')}")
PY
```

States to expect:
- `WAITING_FOR_REVIEW` — submitted, sitting in Apple's queue (typically 1-6h)
- `IN_REVIEW` — reviewer picked it up
- `APPROVED` / `READY_TO_SUBMIT` — done (note: Apple's terminology is inconsistent here; "APPROVED" is the live state)
- `REJECTED` — see `developerNotes` in the response

## Submit IAPs for review (re-submission)

Used in the 2026-05-28 IAP recovery — first submission silently stalled bundled to rejected build 89. Standalone re-submit:

```bash
for AID in 6762097906 6762098097 6762098056 6762097872; do
  curl -sS -X POST \
    -H "Authorization: Bearer $T" \
    -H "Content-Type: application/json" \
    "https://api.appstoreconnect.apple.com/v1/inAppPurchaseSubmissions" \
    -d "{\"data\":{\"type\":\"inAppPurchaseSubmissions\",\"relationships\":{\"inAppPurchaseV2\":{\"data\":{\"type\":\"inAppPurchases\",\"id\":\"$AID\"}}}}}" \
    | python3 -m json.tool | head -5
done
```

Expect HTTP 201 with a fresh submission id per product.

## Don't trust `state` blindly

App Privacy data-type declarations are **not** exposed via public ASC API. To verify "App Privacy" labels you must inspect the web UI (Chrome MCP works). Same goes for some review-submission fields — when in doubt, log into appstoreconnect.apple.com.

## Related

- [`apple-reject-recovery.md`](./apple-reject-recovery.md) — when Apple rejects a version
- [`ios-cli-release.md`](./ios-cli-release.md) — building + uploading a new build
- [`../state/app-store.yaml`](../state/app-store.yaml) — current IDs / states
- [`../incidents/2026-05-28-apple-2.3-reject.md`](../incidents/2026-05-28-apple-2.3-reject.md) — IAP submission stall context
