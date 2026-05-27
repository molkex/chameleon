package admin

import (
	"bufio"
	"encoding/json"
	"net/http"
	"os"
	"sort"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

// MON-06: read the per-minute JSONL summary produced by
// scripts/singbox-log-watcher.py and aggregate it for the admin
// Status page. Aggregating at request time (rather than maintaining a
// rollup in Redis) keeps the moving parts to one: just the file and
// this handler. At the current volume (~300 errors/h, one JSONL line
// per minute = 1440 lines for 24h) the read is microseconds.

const handshakeLogPath = "/var/log/singbox-events.jsonl"

type handshakeTickRow struct {
	TS         string            `json:"ts"`
	Errors     int               `json:"errors"`
	ByIP       map[string]int    `json:"by_ip"`
	Users      map[string]string `json:"users,omitempty"`        // Phase 2+ : {ip: vpn_username}
	UserErrors int               `json:"user_errors,omitempty"`  // Phase 2+
	BotErrors  int               `json:"bot_errors,omitempty"`   // Phase 2+
}

type handshakeHourBucket struct {
	HourStart   string `json:"hour_start"` // YYYY-MM-DDTHH:00:00Z
	Errors      int    `json:"errors"`
	UserErrors  int    `json:"user_errors"`
	BotErrors   int    `json:"bot_errors"`
}

type handshakeTopIP struct {
	IP          string `json:"ip"`
	Errors      int    `json:"errors"`
	VPNUsername string `json:"vpn_username,omitempty"` // Phase 2+ — set when IP matches a real user
}

type handshakeAffectedUser struct {
	VPNUsername string `json:"vpn_username"`
	IP          string `json:"ip"`
	Errors      int    `json:"errors"`
}

type handshakeErrorsResponse struct {
	WindowHours    int                     `json:"window_hours"`
	Total          int                     `json:"total"`
	UserErrors     int                     `json:"user_errors"`
	BotErrors      int                     `json:"bot_errors"`
	Hourly         []handshakeHourBucket   `json:"hourly"`
	TopIPs         []handshakeTopIP        `json:"top_ips"`
	AffectedUsers  []handshakeAffectedUser `json:"affected_users"`
	WatcherOK      bool                    `json:"watcher_ok"`
	WatcherNote    string                  `json:"watcher_note,omitempty"`
}

// GetHandshakeErrors handles GET /api/v1/admin/status/handshake-errors.
//
// Reads the singbox watcher's JSONL output, buckets the last `hours`
// hours' worth of ticks (default 24, clamped 1..72), and returns:
//   - hourly counters
//   - top 10 offending source IPs in the window
//   - a `watcher_ok` flag so the admin can tell the difference between
//     "VPN is healthy" and "watcher isn't running, we don't actually know"
func (h *Handler) GetHandshakeErrors(c echo.Context) error {
	hours := 24
	if s := c.QueryParam("hours"); s != "" {
		if v, err := time.ParseDuration(s + "h"); err == nil {
			hours = int(v.Hours())
		}
	}
	if hours < 1 {
		hours = 1
	}
	if hours > 72 {
		hours = 72
	}

	cutoff := time.Now().UTC().Add(-time.Duration(hours) * time.Hour)

	f, err := os.Open(handshakeLogPath)
	if err != nil {
		// File missing → watcher hasn't run yet (or path mis-configured).
		// Don't 500 — return an empty response with the flag flipped so
		// the SPA can render an "install the watcher" hint.
		resp := handshakeErrorsResponse{
			WindowHours: hours,
			WatcherOK:   false,
			WatcherNote: "singbox watcher log not found at " + handshakeLogPath + " — cron may be missing",
		}
		if !os.IsNotExist(err) {
			h.Logger.Warn("handshake-errors: open", zap.Error(err))
			resp.WatcherNote = "watcher log open failed: " + err.Error()
		}
		return c.JSON(http.StatusOK, resp)
	}
	defer f.Close()

	type hourAgg struct{ total, user, bot int }
	hourBuckets := make(map[string]*hourAgg)
	ipBuckets := make(map[string]int)
	ipToUsername := make(map[string]string) // last-wins, but stable within window
	total := 0
	userTotal := 0
	botTotal := 0
	latestTick := time.Time{}

	scanner := bufio.NewScanner(f)
	// JSONL lines are small (one minute aggregate) but allow large buffer
	// in case by_ip explodes during an attack — token errors here would
	// silently truncate which is worse than allocating.
	buf := make([]byte, 0, 1024*1024)
	scanner.Buffer(buf, 1024*1024)

	for scanner.Scan() {
		var row handshakeTickRow
		if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
			continue // skip malformed lines, don't blow up the endpoint
		}
		t, err := time.Parse(time.RFC3339, row.TS)
		if err != nil {
			continue
		}
		if t.Before(cutoff) {
			continue
		}
		if t.After(latestTick) {
			latestTick = t
		}
		// Hour bucket key: round-down to hour boundary.
		hourKey := t.Truncate(time.Hour).Format(time.RFC3339)
		agg := hourBuckets[hourKey]
		if agg == nil {
			agg = &hourAgg{}
			hourBuckets[hourKey] = agg
		}
		agg.total += row.Errors
		total += row.Errors

		// Phase 2 fields are optional — older JSONL lines from Phase 1
		// have row.UserErrors=0 and row.BotErrors=0 even when errors>0.
		// Detect via the presence of the row.Users map (only Phase 2+
		// emits it). When missing, fall back to "treat all as bot" so
		// the rollup doesn't double-count.
		if row.Users != nil {
			agg.user += row.UserErrors
			agg.bot += row.BotErrors
			userTotal += row.UserErrors
			botTotal += row.BotErrors
		} else {
			agg.bot += row.Errors
			botTotal += row.Errors
		}

		for ip, n := range row.ByIP {
			ipBuckets[ip] += n
		}
		for ip, username := range row.Users {
			ipToUsername[ip] = username
		}
	}
	if err := scanner.Err(); err != nil {
		h.Logger.Warn("handshake-errors: scan", zap.Error(err))
	}

	// Pad the hourly array with zeros so the SPA chart x-axis is dense
	// (same shape as the funnel page's signups/DAU calendar padding).
	now := time.Now().UTC().Truncate(time.Hour)
	hourly := make([]handshakeHourBucket, 0, hours)
	for i := hours - 1; i >= 0; i-- {
		ht := now.Add(-time.Duration(i) * time.Hour)
		key := ht.Format(time.RFC3339)
		agg := hourBuckets[key]
		if agg == nil {
			agg = &hourAgg{}
		}
		hourly = append(hourly, handshakeHourBucket{
			HourStart:  key,
			Errors:     agg.total,
			UserErrors: agg.user,
			BotErrors:  agg.bot,
		})
	}

	// Top 10 IPs by count in the window. Annotate with vpn_username so
	// the admin can scan the table and immediately spot real users that
	// keep failing — those rows render highlighted in the SPA.
	type ipPair struct {
		ip string
		n  int
	}
	pairs := make([]ipPair, 0, len(ipBuckets))
	for ip, n := range ipBuckets {
		pairs = append(pairs, ipPair{ip, n})
	}
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].n > pairs[j].n })
	topN := 10
	if len(pairs) < topN {
		topN = len(pairs)
	}
	topIPs := make([]handshakeTopIP, 0, topN)
	for _, p := range pairs[:topN] {
		topIPs = append(topIPs, handshakeTopIP{
			IP:          p.ip,
			Errors:      p.n,
			VPNUsername: ipToUsername[p.ip], // empty for bots
		})
	}

	// Dedicated "affected users" list — drop the bot IPs entirely so the
	// admin can see the 3 real users failing in front of an unmuted page.
	affected := make([]handshakeAffectedUser, 0)
	for ip, username := range ipToUsername {
		if username == "" {
			continue
		}
		affected = append(affected, handshakeAffectedUser{
			VPNUsername: username,
			IP:          ip,
			Errors:      ipBuckets[ip],
		})
	}
	sort.Slice(affected, func(i, j int) bool { return affected[i].Errors > affected[j].Errors })

	// Watcher fresh if we saw a tick in the last 5 minutes. Anything
	// older = cron isn't running or the docker logs call is failing.
	watcherOK := !latestTick.IsZero() && time.Since(latestTick) < 5*time.Minute
	resp := handshakeErrorsResponse{
		WindowHours:   hours,
		Total:         total,
		UserErrors:    userTotal,
		BotErrors:     botTotal,
		Hourly:        hourly,
		TopIPs:        topIPs,
		AffectedUsers: affected,
		WatcherOK:     watcherOK,
	}
	if !watcherOK {
		if latestTick.IsZero() {
			resp.WatcherNote = "no ticks recorded — watcher not running"
		} else {
			resp.WatcherNote = "last tick " + latestTick.Format(time.RFC3339) + " is stale"
		}
	}
	return c.JSON(http.StatusOK, resp)
}
