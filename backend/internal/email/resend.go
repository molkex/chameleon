package email

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"go.uber.org/zap"
)

// ResendSender sends via the Resend HTTP API. Lightweight: one HTTP POST
// per message, no long-lived connections.
//
// Docs: https://resend.com/docs/api-reference/emails/send-email
type ResendSender struct {
	apiKey   string
	fromAddr string // e.g. "MadFrog VPN <info@madfrog.online>"
	http     *http.Client
	logger   *zap.Logger
}

// NewResendSender returns a sender, or nil if apiKey/fromEmail are empty.
// Callers should fall back to NoopSender in that case.
func NewResendSender(apiKey, fromEmail, fromName string, logger *zap.Logger) *ResendSender {
	if apiKey == "" || fromEmail == "" {
		return nil
	}
	from := fromEmail
	if fromName != "" {
		from = fmt.Sprintf("%s <%s>", fromName, fromEmail)
	}
	return &ResendSender{
		apiKey:   apiKey,
		fromAddr: from,
		http:     &http.Client{Timeout: 10 * time.Second},
		logger:   logger.Named("email.resend"),
	}
}

type resendRequest struct {
	From    string   `json:"from"`
	To      []string `json:"to"`
	Subject string   `json:"subject"`
	HTML    string   `json:"html,omitempty"`
	Text    string   `json:"text,omitempty"`
}

type resendResponse struct {
	ID      string `json:"id"`
	Message string `json:"message,omitempty"`
	Name    string `json:"name,omitempty"`
}

func (s *ResendSender) Send(ctx context.Context, msg Message) error {
	body := resendRequest{
		From:    s.fromAddr,
		To:      []string{msg.To},
		Subject: msg.Subject,
		HTML:    msg.HTMLBody,
		Text:    msg.TextBody,
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal resend request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://api.resend.com/emails", bytes.NewReader(buf))
	if err != nil {
		return fmt.Errorf("build resend request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+s.apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.http.Do(req)
	if err != nil {
		return fmt.Errorf("resend http: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		s.logger.Warn("resend rejected message",
			zap.Int("status", resp.StatusCode),
			zap.String("body", string(respBody)),
			zap.String("to", msg.To))
		return fmt.Errorf("resend: %d %s", resp.StatusCode, string(respBody))
	}

	var parsed resendResponse
	_ = json.Unmarshal(respBody, &parsed)
	s.logger.Info("email sent",
		zap.String("id", parsed.ID),
		zap.String("to", msg.To),
		zap.String("subject", msg.Subject))
	return nil
}

// NoopSender silently drops every message. Used when email is not configured
// so the auth flow doesn't fail hard on dev/staging without SMTP creds.
type NoopSender struct {
	logger *zap.Logger
}

func NewNoopSender(logger *zap.Logger) *NoopSender {
	return &NoopSender{logger: logger.Named("email.noop")}
}

func (s *NoopSender) Send(_ context.Context, msg Message) error {
	s.logger.Warn("email provider not configured — dropping message",
		zap.String("to", msg.To),
		zap.String("subject", msg.Subject))
	return nil
}
