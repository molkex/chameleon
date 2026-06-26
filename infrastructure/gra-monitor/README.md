# GRA external monitor (NL-RED-MON)

External, **off-Timeweb** health monitor for the NL control-plane origin. Runs on the
GRA box (OVH Gravelines, `debian@54.38.243.162`) so a Timeweb/NL outage cannot silence
it — unlike `backend/scripts/health-check.sh`, which runs ON NL and went mute during the
[2026-06-26 outage](../../docs/incidents/2026-06-26-timeweb-nl-ams1-outage.md).
Part of [ADR 0012](../../docs/decisions/0012-nl-redundancy-warm-standby.md), roadmap
`NL-RED-01 → phase_0_now → NL-RED-MON`.

## What it does

Every 5 min (systemd timer) probes from the GRA vantage:
- `GET https://api.madfrog.online/health` (user-facing path: MSK relay → NL)
- direct TCP to `147.45.252.234:80` and `:443`

Alerts to Telegram on **state transitions** (so no spam):
- 🔴 `NL origin unreachable` — api fails AND NL:80 is down from GRA
- 🟠 `NL origin UP but api.madfrog.online failing` — NL:80 up but api fails → suspect MSK relay / nginx
- ✅ `NL ORIGIN RECOVERED` — api back to 200
- re-alerts at most every 30 min while still down

## Files (mirrored on the box at `/home/debian/monitoring/`)

- `nl-origin-healthcheck.sh` — the probe (in this repo)
- `telegram-alert.sh` — TG sender (sources `chameleon-alerts.env`; same as MSK)
- `chameleon-alerts.env` — `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_IDS` (NOT in repo; copied from MSK `/etc/chameleon-alerts.env`, chmod 600)
- `.nl-origin.state` / `.nl-origin.lastalert` — runtime state (not in repo)

## systemd units (on the box)

- `/etc/systemd/system/nl-origin-mon.service` (Type=oneshot, User=debian)
- `/etc/systemd/system/nl-origin-mon.timer` (OnUnitActiveSec=5min) — `enabled --now`

## Install / restore

```bash
GRA=debian@54.38.243.162; KEY=~/.ssh/claude-code-ssh-key
ssh -i $KEY $GRA 'mkdir -p ~/monitoring'
scp -i $KEY infrastructure/gra-monitor/nl-origin-healthcheck.sh $GRA:~/monitoring/
# telegram-alert.sh: local-config variant; chameleon-alerts.env: copy from MSK /etc/
ssh -i $KEY root@217.198.5.52 'cat /etc/chameleon-alerts.env' | ssh -i $KEY $GRA 'cat > ~/monitoring/chameleon-alerts.env && chmod 600 ~/monitoring/chameleon-alerts.env'
ssh -i $KEY $GRA 'chmod +x ~/monitoring/*.sh'
# then install the systemd .service + .timer (see units above) and: sudo systemctl enable --now nl-origin-mon.timer
```

## Verify

```bash
ssh -i ~/.ssh/claude-code-ssh-key debian@54.38.243.162 \
  'systemctl is-active nl-origin-mon.timer; tail -5 ~/monitoring/nl-origin.log'
```

## TODO (phase 0 remainder)

- Balance alarm (`Timeweb finances.hours_left < 72`) — needs a **read-only / scoped**
  Timeweb API key; do NOT place the full account API key on this exit node.
