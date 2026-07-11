# MSK relay monitoring (external, off-primary vantage)

External, **off-primary** health monitors for the control-plane, both running on
the MSK relay (`root@217.198.5.52`) so an outage of WAW itself cannot silence them
— unlike `backend/scripts/health-check.sh`, which runs ON the primary and went mute
during the [2026-06-26 NL outage](../../docs/incidents/2026-06-26-timeweb-nl-ams1-outage.md).
Part of [ADR 0012](../../docs/decisions/0012-nl-redundancy-warm-standby.md).

> **2026-07-11:** `waw-origin-healthcheck.sh` moved here from the now-decommissioned
> GRA box (`infrastructure/gra-monitor/`, removed). France/GRA was cut (zero real
> usage in 14d telemetry) — see `docs/incidents/` / roadmap for the full account.
> MSK isn't as geographically distinct from WAW as GRA was, but it's still a
> different provider (Timeweb vs OVH) and a different box, which is what actually
> matters for "an outage of WAW's own network can't silence the monitor."

## What's here

- **`ru-auth-healthcheck.sh`** — probes RU sign-in from a real RU vantage (live
  since 2026-06). Alerts on `auth.attempt` failures via Telegram.
- **`waw-origin-healthcheck.sh`** — every 5 min (cron) probes `GET
  https://madfrog.online/health` — the public origin the way a visitor hits it
  (Cloudflare → WAW:80 → nginx → backend :8000). CF returns 52x when the origin is
  actually down, so a non-200 means WAW is unreachable. Alerts on **state
  transitions with flap damping** (no spam): 🔴 down after 2 consecutive fails, ✅
  recovered, re-alerts at most every 30 min while still down.
- **`telegram-alert.sh`** — shared TG sender for both scripts above (sources
  `/etc/chameleon-alerts.env` on the box — `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_IDS`,
  NOT in repo).

**Not probed by either script:** if the MSK relay itself dies, both monitors go
mute — a dedicated reliable external probe from a 3rd vantage is future work
(roadmap `SYNTHETIC-MONITOR`).

## Install / restore (on MSK)

```bash
MSK=root@217.198.5.52; KEY=~/.ssh/claude-code-ssh-key
scp -i $KEY infrastructure/monitoring/waw-origin-healthcheck.sh infrastructure/monitoring/telegram-alert.sh $MSK:/opt/chameleon/monitoring/
ssh -i $KEY $MSK 'chmod +x /opt/chameleon/monitoring/*.sh'
ssh -i $KEY $MSK "(crontab -l 2>/dev/null; echo '*/5 * * * * /opt/chameleon/monitoring/waw-origin-healthcheck.sh >> /var/log/waw-origin-healthcheck.log 2>&1') | crontab -"
```

## Verify

```bash
ssh -i ~/.ssh/claude-code-ssh-key root@217.198.5.52 \
  'crontab -l | grep waw-origin; tail -5 /var/log/waw-origin-healthcheck.log'
```
