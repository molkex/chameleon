// Package lifecycle implements the A1 re-engagement engine
// (PRODUCT-MATURITY-LOOP, 2026-06-21): a daily sweep that finds users whose
// subscription/trial is about to lapse or recently lapsed and sends them a
// push + email reminder exactly once per cycle. This is the direct counter to
// "buy once, never come back" — non-renewing subs need a reminder to renew.
//
// DISABLED by default (config.lifecycle.enabled=false). With dry_run=true the
// engine logs exactly who WOULD be contacted and sends nothing — use it to
// review reach + copy before going live.
//
// Window() and Compose() are pure and unit-tested; Sweep() wires them to the
// DB + push + email senders.
package lifecycle

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/email"
	"github.com/chameleonvpn/chameleon/internal/push"
	"go.uber.org/zap"
)

// Kind is a lifecycle reminder stage.
type Kind string

const (
	KindExpiringSoon   Kind = "expiring_soon"   // active, ends within 24h
	KindExpiredRecent  Kind = "expired_recent"  // lapsed within the last 24h
	KindExpiredWinback Kind = "expired_winback" // lapsed 7-8 days ago (win-back)
)

// AllKinds is the sweep order.
var AllKinds = []Kind{KindExpiringSoon, KindExpiredRecent, KindExpiredWinback}

// Window returns the [lo, hi) subscription_expiry range selecting users for
// `kind` at time `now`. A 24h "expiring" window (not 72h) avoids telling a
// freshly-registered 3-day-trial user "expires in 3 days" on day 0. The daily
// sweep + the per-(user,kind,expiry) unique index guarantee a single send.
func Window(kind Kind, now time.Time) (lo, hi time.Time, ok bool) {
	day := 24 * time.Hour
	switch kind {
	case KindExpiringSoon:
		return now, now.Add(day), true
	case KindExpiredRecent:
		return now.Add(-day), now, true
	case KindExpiredWinback:
		return now.Add(-8 * day), now.Add(-7 * day), true
	default:
		return time.Time{}, time.Time{}, false
	}
}

// Notification is the composed copy for one reminder.
type Notification struct {
	PushTitle    string
	PushBody     string
	EmailSubject string
	EmailHTML    string
	EmailText    string
}

// Compose builds user-facing copy. paid distinguishes a lapsing PAID subscriber
// (renew) from a TRIAL user (convert). lang is "ru" (default) or "en". cta is
// the URL the email button points at.
//
// OWNER: this copy reaches real customers — review before enabling the engine.
func Compose(kind Kind, paid bool, lang, cta string) Notification {
	en := strings.HasPrefix(strings.ToLower(lang), "en")

	var heading, body, push string
	switch kind {
	case KindExpiringSoon:
		if en {
			heading = "Your access ends tomorrow"
			if paid {
				body = "Your MadFrog VPN subscription expires within 24 hours. Renew now to stay protected without interruption."
			} else {
				body = "Your free trial ends within 24 hours. Subscribe now to keep your VPN protection."
			}
			push = "Renew to stay protected — your access ends tomorrow."
		} else {
			heading = "Доступ заканчивается завтра"
			if paid {
				body = "Подписка MadFrog VPN истекает в течение суток. Продлите сейчас, чтобы защита не прерывалась."
			} else {
				body = "Бесплатный период заканчивается в течение суток. Оформите подписку, чтобы сохранить защиту."
			}
			push = "Продлите подписку — доступ заканчивается завтра."
		}
	case KindExpiredRecent:
		if en {
			heading = "Your VPN protection has ended"
			if paid {
				body = "Your subscription has expired. Renew in a tap to turn protection back on."
			} else {
				body = "Your free trial has ended. Subscribe to turn your VPN protection back on."
			}
			push = "Your protection ended — renew in a tap."
		} else {
			heading = "Защита VPN отключена"
			if paid {
				body = "Подписка истекла. Продлите в одно касание, чтобы снова включить защиту."
			} else {
				body = "Бесплатный период закончился. Оформите подписку, чтобы снова включить защиту."
			}
			push = "Защита отключена — продлите в одно касание."
		}
	case KindExpiredWinback:
		if en {
			heading = "We saved your spot — come back"
			body = "It's been a week since your MadFrog VPN access ended. Come back and protect your connection again — open the app to see your options."
			push = "Miss your VPN? Come back and reconnect."
		} else {
			heading = "Возвращайтесь — мы вас ждём"
			body = "Прошло уже неделя с тех пор, как закончился доступ к MadFrog VPN. Возвращайтесь и снова защитите соединение — откройте приложение, чтобы увидеть варианты."
			push = "Скучаете по VPN? Возвращайтесь и подключайтесь снова."
		}
	}

	ctaLabel := "Открыть приложение"
	if en {
		ctaLabel = "Open the app"
	}

	return Notification{
		PushTitle:    "MadFrog VPN",
		PushBody:     push,
		EmailSubject: heading,
		EmailHTML:    emailHTML(heading, body, ctaLabel, cta),
		EmailText:    body + "\n\n" + cta,
	}
}

func emailHTML(heading, body, ctaLabel, cta string) string {
	btn := ""
	if cta != "" {
		btn = fmt.Sprintf(
			`<p style="margin:28px 0"><a href="%s" style="background:#A3E635;color:#0B0B0F;text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600;display:inline-block">%s</a></p>`,
			cta, ctaLabel)
	}
	return fmt.Sprintf(`<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#111">
<h2 style="margin:0 0 12px">%s</h2>
<p style="margin:0;line-height:1.5;color:#333">%s</p>
%s
<p style="margin:24px 0 0;font-size:12px;color:#999">MadFrog VPN</p>
</div>`, heading, body, btn)
}

// Engine runs the sweep. Push/Email may be nil (channel skipped).
type Engine struct {
	DB     *db.DB
	Push   *push.Client
	Email  email.Sender
	Logger *zap.Logger
	CTA    string // deep link / URL for the email CTA
	DryRun bool   // log who would be contacted; send + record nothing
}

// Sweep runs all reminder windows once. Safe to call on a daily ticker; the DB
// unique index makes a re-run within the same window a no-op.
func (e *Engine) Sweep(ctx context.Context) {
	now := time.Now()
	for _, kind := range AllKinds {
		lo, hi, ok := Window(kind, now)
		if !ok {
			continue
		}
		cands, err := e.DB.LifecycleCandidates(ctx, string(kind), lo, hi)
		if err != nil {
			e.Logger.Warn("lifecycle: candidate query failed", zap.String("kind", string(kind)), zap.Error(err))
			continue
		}
		if len(cands) == 0 {
			continue
		}
		e.Logger.Info("lifecycle: window candidates", zap.String("kind", string(kind)), zap.Int("count", len(cands)), zap.Bool("dry_run", e.DryRun))
		for _, c := range cands {
			select {
			case <-ctx.Done():
				return
			default:
			}
			e.process(ctx, kind, c)
		}
	}
}

func (e *Engine) process(ctx context.Context, kind Kind, c db.LifecycleCandidate) {
	// Language: we don't persist a per-user locale yet → default RU (our core
	// market). EN is selectable once a locale column exists (logged as a gap).
	msg := Compose(kind, c.HasPaid, "ru", e.CTA)

	var channels []string

	// Push to every registered token.
	tokens, err := e.DB.PushTokensForUser(ctx, c.UserID)
	if err != nil {
		e.Logger.Warn("lifecycle: token lookup failed", zap.Int64("user", c.UserID), zap.Error(err))
	}
	pushed := 0
	for _, tok := range tokens {
		if e.DryRun || e.Push == nil {
			pushed++
			continue
		}
		switch err := e.Push.Send(ctx, tok, msg.PushTitle, msg.PushBody, map[string]any{
			"type": "lifecycle", "kind": string(kind), "url": e.CTA,
		}); {
		case err == nil:
			pushed++
		case errors.Is(err, push.ErrBadToken):
			_ = e.DB.DeletePushToken(ctx, tok)
		default:
			e.Logger.Warn("lifecycle: push send failed", zap.Int64("user", c.UserID), zap.Error(err))
		}
	}
	if pushed > 0 {
		channels = append(channels, "push")
	}

	// Email if we have an address.
	if c.Email != nil && *c.Email != "" {
		if e.DryRun || e.Email == nil {
			channels = append(channels, "email")
		} else if err := e.Email.Send(ctx, email.Message{
			To: *c.Email, Subject: msg.EmailSubject, HTMLBody: msg.EmailHTML, TextBody: msg.EmailText,
		}); err != nil {
			e.Logger.Warn("lifecycle: email send failed", zap.Int64("user", c.UserID), zap.Error(err))
		} else {
			channels = append(channels, "email")
		}
	}

	if e.DryRun {
		e.Logger.Info("lifecycle: DRY-RUN would notify",
			zap.Int64("user", c.UserID), zap.String("kind", string(kind)),
			zap.Bool("paid", c.HasPaid), zap.Strings("channels", channels))
		return
	}
	if len(channels) == 0 {
		// Nothing delivered (no token, no email) — don't burn the once-only slot.
		return
	}
	if err := e.DB.RecordLifecycleReminder(ctx, c.UserID, string(kind), c.Expiry, strings.Join(channels, ",")); err != nil {
		e.Logger.Warn("lifecycle: record failed", zap.Int64("user", c.UserID), zap.Error(err))
	}
}
