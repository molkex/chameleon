#!/usr/bin/env bash
# ============================================================
#  sim-run.sh — build MadFrogVPN + run it in the iOS Simulator + screenshot.
# ============================================================
# Enables autonomous UI/flow verification WITHOUT a physical device (everything
# except the actual VPN tunnel — NetworkExtension doesn't run in the Simulator).
#
# Gotcha baked in: the app MUST be built WITH signing/entitlements, else it
# crashes at launch on `app_group_identifier: client is not entitled` (the
# group.com.madfrog.vpn shared container). So NO `CODE_SIGNING_ALLOWED=NO`.
#
# Usage:
#   ./scripts/sim-run.sh                  # build + launch + screenshot to /tmp/madfrog-sim.png
#   ./scripts/sim-run.sh "iPhone 17 Pro"  # pick a sim
#   SHOT=/tmp/x.png ./scripts/sim-run.sh  # custom screenshot path
set -euo pipefail
cd "$(dirname "$0")/.."

SIM="${1:-iPhone 17}"
SHOT="${SHOT:-/tmp/madfrog-sim.png}"
BUNDLE="com.madfrog.vpn"

echo ">>> xcodegen"; xcodegen generate >/dev/null
echo ">>> build (signed, iOS Simulator: $SIM)"
xcodebuild -project MadFrogVPN.xcodeproj -scheme MadFrogVPN \
  -destination "platform=iOS Simulator,name=$SIM" \
  -configuration Debug -allowProvisioningUpdates build 2>&1 | tail -1

APP=$(xcodebuild -project MadFrogVPN.xcodeproj -scheme MadFrogVPN \
  -destination "platform=iOS Simulator,name=$SIM" -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')
echo ">>> app: $APP"

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" "$BUNDLE"
sleep 5
xcrun simctl io "$SIM" screenshot "$SHOT"
echo ">>> screenshot: $SHOT"
echo ">>> app log (last 30s, errors):"
xcrun simctl spawn "$SIM" log show --last 30s --predicate "subsystem == \"$BUNDLE\"" 2>/dev/null | tail -5 || true
