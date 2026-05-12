#!/bin/bash
# Chameleon — pre-deploy guard
# Sourced from backend/deploy.sh before any remote action.
#
# Purpose: refuse to deploy code that isn't on origin/main.
# Background: iOS builds 50–53 shipped to App Store Connect without ever being
# committed/pushed → zero audit trail for what's actually in production. We
# extend the same discipline to backend deploys.
#
# Exit codes:
#   0 — clean tree, HEAD pushed to origin/main, deploy may proceed
#   1 — uncommitted changes / unpushed commits / detached HEAD — abort
#
# Override (use SPARINGLY, only for emergency hotfixes):
#   ALLOW_DIRTY_DEPLOY=1 ./deploy.sh ...

set -euo pipefail

# Run from the repo root regardless of caller's cwd.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: predeploy-check must run inside a git checkout" >&2
    exit 1
fi
cd "$REPO_ROOT"

fail() {
    echo "" >&2
    echo "╔══════════════════════════════════════════════════════════════════╗" >&2
    echo "║  PRE-DEPLOY CHECK FAILED — refusing to deploy                    ║" >&2
    echo "╚══════════════════════════════════════════════════════════════════╝" >&2
    echo "" >&2
    echo "$1" >&2
    echo "" >&2
    if [ "${ALLOW_DIRTY_DEPLOY:-0}" = "1" ]; then
        echo "⚠ ALLOW_DIRTY_DEPLOY=1 set — proceeding anyway (emergency override)." >&2
        return 0
    fi
    echo "If this is an emergency hotfix and you accept zero audit trail," >&2
    echo "re-run with: ALLOW_DIRTY_DEPLOY=1 $0 ..." >&2
    exit 1
}

# 1. Working tree must be clean.
if [ -n "$(git status --porcelain)" ]; then
    fail "Uncommitted / untracked changes present:
$(git status --short)

Commit and push them before deploying."
fi

# 2. HEAD must be on a known branch (not detached).
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
    fail "Detached HEAD — checkout a branch (usually main) before deploying."
fi

# 3. origin/main must be in sync with what we're deploying.
#    HEAD must be an ancestor of (or equal to) origin/main.
git fetch --quiet origin main 2>/dev/null || fail "Cannot reach origin to verify main — check network/credentials."

HEAD_SHA="$(git rev-parse HEAD)"
ORIGIN_MAIN_SHA="$(git rev-parse origin/main)"

if [ "$HEAD_SHA" != "$ORIGIN_MAIN_SHA" ]; then
    # Allow case where HEAD is strictly behind origin/main? No — we deploy
    # the local tree, so if local != origin/main we have ambiguity.
    if git merge-base --is-ancestor "$HEAD_SHA" "$ORIGIN_MAIN_SHA" 2>/dev/null; then
        fail "Local HEAD ($HEAD_SHA) is behind origin/main ($ORIGIN_MAIN_SHA).
Run: git pull --ff-only origin main"
    elif git merge-base --is-ancestor "$ORIGIN_MAIN_SHA" "$HEAD_SHA" 2>/dev/null; then
        fail "Local HEAD ($HEAD_SHA) has commits NOT pushed to origin/main.
Run: git push origin $CURRENT_BRANCH:main
(or open a PR if you want review first)"
    else
        fail "Local HEAD and origin/main have diverged.
  local:       $HEAD_SHA
  origin/main: $ORIGIN_MAIN_SHA
Reconcile (rebase/merge/push) before deploying."
    fi
fi

echo "✓ pre-deploy check passed (HEAD $HEAD_SHA on origin/main, tree clean)"
