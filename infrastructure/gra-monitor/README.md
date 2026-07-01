# GRA external monitor (WAW-origin, was NL-RED-MON)

External, **off-primary** health monitor for the control-plane origin. Runs on the
GRA box (OVH Gravelines, `debian@54.38.243.162`) so an outage of the primary cannot
silence it — unlike `backend/scripts/health-check.sh`, which runs ON the primary and
went mute during the [2026-06-26 NL outage](../../docs/incidents/2026-06-26-timeweb-nl-ams1-outage.md).
Part of [ADR 0012](../../docs/decisions/0012-nl-redundancy-warm-standby.md).

> **2026-07-01:** after the NL→WAW failover, NL is retired as the origin and **WAW**
> is primary. This monitor was repointed NL → WAW: `nl-origin-healthcheck.sh` →
> `waw-origin-healthcheck.sh`, systemd `nl-origin-mon.*` → `waw-origin-mon.*`.

## What it does

Every 5 min (systemd timer) probes from the GRA vantage:
- `GET https://madfrog.online/health` — the public origin the way a visitor hits it
  (Cloudflare → WAW:80 → nginx → backend :8000). CF returns 52x when the origin is
  actually down, so a non-200 means WAW is unreachable.

Alerts to Telegram on **state transitions with flap damping** (no spam):
- 🔴 `WAW origin unreachable via Cloudflare` — after `$CONFIRM` (2) consecutive fails
- ✅ `WAW ORIGIN RECOVERED` — back to 200
- re-alerts at most every 30 min while still down

**Not probed here:** the RU API ingress `api.madfrog.online` (→ MSK relay → WAW). The
France→Russia hop is slow/flaky and produced false timeouts; it is monitored from a
real RU vantage by `infrastructure/monitoring/ru-auth-healthcheck.sh` **on the MSK
relay**. Gap: if the MSK relay itself dies its on-box monitor goes mute — a dedicated
reliable external RU-ingress probe is future work.

## Files (mirrored on the box at `/home/debian/monitoring/`)

- `waw-origin-healthcheck.sh` — the probe (in this repo)
- `telegram-alert.sh` — TG sender (sources `chameleon-alerts.env`; same as MSK)
- `chameleon-alerts.env` — `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_IDS` (NOT in repo; copied from MSK `/etc/chameleon-alerts.env`, chmod 600)
- `.waw-origin.state` / `.waw-origin.streak` / `.waw-origin.lastalert` — runtime state (not in repo)

## systemd units (on the box)

- `/etc/systemd/system/waw-origin-mon.service` (Type=oneshot, User=debian)
- `/etc/systemd/system/waw-origin-mon.timer` (OnUnitActiveSec=5min) — `enabled --now`

## Install / restore

```bash
GRA=debian@54.38.243.162; KEY=~/.ssh/claude-code-ssh-key
ssh -i $KEY $GRA 'mkdir -p ~/monitoring'
scp -i $KEY infrastructure/gra-monitor/waw-origin-healthcheck.sh $GRA:~/monitoring/
# telegram-alert.sh: local-config variant; chameleon-alerts.env: copy from MSK /etc/
ssh -i $KEY root@217.198.5.52 'cat /etc/chameleon-alerts.env' | ssh -i $KEY $GRA 'cat > ~/monitoring/chameleon-alerts.env && chmod 600 ~/monitoring/chameleon-alerts.env'
ssh -i $KEY $GRA 'chmod +x ~/monitoring/*.sh'
# then install the systemd .service + .timer (see units above) and: sudo systemctl enable --now waw-origin-mon.timer
```

## Verify

```bash
ssh -i ~/.ssh/claude-code-ssh-key debian@54.38.243.162 \
  'systemctl is-active waw-origin-mon.timer; tail -5 ~/monitoring/waw-origin.log'
```
