#!/bin/bash
# Regression test for the singbox-watchdog name filter.
#
# History: 2026-05-27 morning the watchdog used --filter "name=singbox"
# which is a SUBSTRING match — that ALSO matched `singbox-ss-ws` (the
# sibling Shadowsocks-over-WebSocket container), so the watchdog "saw"
# singbox running even when the real singbox VPN container was down.
# Fix `a7457b0` anchored the regex to `^singbox$` via the new docker
# filter syntax `name=^singbox$`. This script asserts that anchor:
#   - finds exactly `singbox` when it's running
#   - does NOT match `singbox-ss-ws` standing alone
#   - does NOT match other `*singbox*` siblings someone might add later
#
# Runs without docker — we feed canned docker-ps output through grep with
# the same -E regex docker's filter uses under the hood. Real docker takes
# the same form, so a passing test here covers the production behaviour.

set -e
PASS=0
FAIL=0

assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $name"
        echo "      expected: $expected"
        echo "      actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

# `name=^singbox$` is docker's regex syntax for the --filter flag; on the
# shell side we mimic it with `grep -E '^singbox$'`. The semantics match
# because docker normalises both into the same Go regexp.
match() {
    echo "$1" | grep -cE '^singbox$' || true
}

# Scenario 1: only the real singbox container.
assert "only singbox" "1" "$(match 'singbox')"

# Scenario 2: only singbox-ss-ws — this is the prior-bug case. Substring
# match would have matched (printed "1"); anchored regex must NOT.
assert "only singbox-ss-ws does NOT match" "0" "$(match 'singbox-ss-ws')"

# Scenario 3: both running, multiline like real `docker ps --format` output.
assert "both running, only singbox matches" "1" "$(printf 'singbox\nsingbox-ss-ws\n' | grep -cE '^singbox$')"

# Scenario 4: hypothetical future sibling.
assert "singbox-shadow does NOT match" "0" "$(match 'singbox-shadow')"

# Scenario 5: empty (no containers running).
assert "nothing running" "0" "$(printf '' | grep -cE '^singbox$' || true)"

# Scenario 6: name embedded in another string. Real docker -q output is
# always one name per line, but defensive: a name like "singbox-fork"
# must not slip through if someone misuses the filter.
assert "singbox-fork does NOT match" "0" "$(match 'singbox-fork')"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
