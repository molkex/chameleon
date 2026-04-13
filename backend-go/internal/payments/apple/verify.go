// Package apple verifies Apple App Store signed transactions (JWS) for IAP flows.
//
// StoreKit 2 on the client returns a signed JWS for every transaction. This package
// verifies the JWS signature chain (leaf → intermediate → Apple root CA) using
// awa/go-iap, then enforces app-level invariants (bundle id, environment, expiry,
// product id). Credentials for App Store Server API (issuer id / key id / .p8) are
// NOT required for verification — only for outbound API calls (transaction lookup,
// notifications history), which are handled elsewhere.
package apple

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/awa/go-iap/appstore"
	iap "github.com/awa/go-iap/appstore/api"
)

// Environment matches Apple's signed transaction environment field.
type Environment string

const (
	EnvProduction Environment = "Production"
	EnvSandbox    Environment = "Sandbox"
)

// Config controls what the verifier accepts.
type Config struct {
	// BundleID the transaction must belong to (e.g. "com.madfrog.vpn"). Required.
	BundleID string
	// AllowSandbox — if true, Sandbox-signed transactions are accepted alongside
	// Production. Production JWS is always accepted. Use true in dev/staging.
	AllowSandbox bool
	// Products maps Apple productId → days of VPN to credit. Unknown products are rejected.
	Products map[string]int
}

// Transaction is the minimal, verified subset of a StoreKit 2 JWS transaction
// that the rest of the backend needs to credit a subscription.
type Transaction struct {
	TransactionID         string
	OriginalTransactionID string // stable id across renewals — use as payments.charge_id
	ProductID             string
	BundleID              string
	Environment           Environment
	PurchaseDate          time.Time
	ExpiresDate           time.Time
	Days                  int // resolved from Config.Products
	Revoked               bool
}

// Verifier parses and validates Apple JWS transactions.
type Verifier struct {
	cfg         Config
	client      *iap.StoreClient
	notifClient *appstore.Client
}

// New creates a verifier. The underlying StoreClient is used only for its JWS
// parse path (x5c chain + ES256 signature verification against Apple's root CA),
// so we pass an empty StoreConfig — no credentials needed.
func New(cfg Config) (*Verifier, error) {
	if cfg.BundleID == "" {
		return nil, errors.New("apple: BundleID is required")
	}
	if len(cfg.Products) == 0 {
		return nil, errors.New("apple: at least one product must be registered")
	}
	client := iap.NewStoreClient(&iap.StoreConfig{})
	return &Verifier{
		cfg:         cfg,
		client:      client,
		notifClient: appstore.New(),
	}, nil
}

// ErrRevoked is returned when Apple has marked the transaction as refunded/revoked.
var ErrRevoked = errors.New("apple: transaction revoked")

// Verify parses signedJWS, verifies its signature chain against Apple's root CA,
// and enforces bundle/environment/product invariants. On success it returns a
// Transaction with Days resolved from cfg.Products — the caller can pass this
// straight to payments.CreditDays.
//
// Errors are descriptive but intentionally coarse: the caller should treat any
// non-nil error as "do not grant access", log it server-side, and return a
// generic failure to the client.
func (v *Verifier) Verify(signedJWS string) (result *Transaction, err error) {
	signedJWS = strings.TrimSpace(signedJWS)
	if signedJWS == "" {
		return nil, errors.New("apple: signed transaction is empty")
	}

	// go-iap's parser indexes x5c[2] without a bounds check, so a JWS with a
	// short cert chain (e.g. Xcode's local StoreKit signing, which ships just
	// one cert) panics deep inside ParseSignedTransaction. Pre-validate the
	// header so we return a clean error instead of a recovered 500.
	if err := assertRealAppleChain(signedJWS); err != nil {
		return nil, err
	}

	// Defense in depth: recover from any residual panics inside go-iap.
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("apple: parse signed transaction panicked: %v", r)
		}
	}()

	jws, err := v.client.ParseSignedTransaction(signedJWS)
	if err != nil {
		return nil, fmt.Errorf("apple: parse signed transaction: %w", err)
	}

	if jws.BundleID != v.cfg.BundleID {
		return nil, fmt.Errorf("apple: bundle id mismatch: got %q, want %q", jws.BundleID, v.cfg.BundleID)
	}

	env := Environment(jws.Environment)
	switch env {
	case EnvProduction:
		// always allowed
	case EnvSandbox:
		if !v.cfg.AllowSandbox {
			return nil, errors.New("apple: sandbox transactions are not accepted")
		}
	default:
		return nil, fmt.Errorf("apple: unknown environment %q", jws.Environment)
	}

	days, ok := v.cfg.Products[jws.ProductID]
	if !ok {
		return nil, fmt.Errorf("apple: unknown product id %q", jws.ProductID)
	}

	if jws.OriginalTransactionId == "" {
		return nil, errors.New("apple: originalTransactionId is empty")
	}

	tx := &Transaction{
		TransactionID:         jws.TransactionID,
		OriginalTransactionID: jws.OriginalTransactionId,
		ProductID:             jws.ProductID,
		BundleID:              jws.BundleID,
		Environment:           env,
		PurchaseDate:          msToTime(jws.PurchaseDate),
		ExpiresDate:           msToTime(jws.ExpiresDate),
		Days:                  days,
		Revoked:               jws.RevocationDate > 0,
	}

	if tx.Revoked {
		return tx, ErrRevoked
	}

	return tx, nil
}

// Notification is the decoded, verified summary of an App Store Server
// Notification V2 payload. It contains the notification type/subtype plus the
// verified inner transaction (same struct we return from Verify).
//
// For DID_RENEW / SUBSCRIBED / REFUND / REVOKE the Tx field is populated.
// For TEST pings and summary-only notifications (e.g. RENEWAL_EXTENSION with
// status summary) Tx may be nil — the caller should treat those as no-ops.
type Notification struct {
	Type    string
	Subtype string
	UUID    string
	Tx      *Transaction
}

// VerifyNotification parses an App Store Server Notification V2 signedPayload,
// verifies the outer JWS against Apple's root CA, then verifies the inner
// signedTransactionInfo (if any) via the same Verify path.
//
// The returned Notification carries both metadata (type/subtype for routing)
// and — when applicable — the verified Transaction the caller should credit
// or revoke.
func (v *Verifier) VerifyNotification(signedPayload string) (*Notification, error) {
	signedPayload = strings.TrimSpace(signedPayload)
	if signedPayload == "" {
		return nil, errors.New("apple: signedPayload is empty")
	}

	var claims appstore.SubscriptionNotificationV2DecodedPayload
	if err := v.notifClient.ParseNotificationV2WithClaim(signedPayload, &claims); err != nil {
		return nil, fmt.Errorf("apple: parse notification: %w", err)
	}

	n := &Notification{
		Type:    string(claims.NotificationType),
		Subtype: string(claims.Subtype),
		UUID:    claims.NotificationUUID,
	}

	// Enforce bundle id on the notification envelope too — this is our first
	// line of defence if someone replays another app's notification at us.
	if claims.Data.BundleID != "" && claims.Data.BundleID != v.cfg.BundleID {
		return nil, fmt.Errorf("apple: notification bundle id mismatch: got %q, want %q",
			claims.Data.BundleID, v.cfg.BundleID)
	}

	innerJWS := string(claims.Data.SignedTransactionInfo)
	if innerJWS == "" {
		// Summary-only or TEST ping — no transaction to credit.
		return n, nil
	}

	tx, err := v.Verify(innerJWS)
	if err != nil && !errors.Is(err, ErrRevoked) {
		return nil, fmt.Errorf("apple: inner transaction: %w", err)
	}
	// Revoked transactions still carry a valid Tx; the caller decides what to do.
	if tx != nil && errors.Is(err, ErrRevoked) {
		tx.Revoked = true
	}
	n.Tx = tx
	return n, nil
}

// assertRealAppleChain rejects JWS tokens whose x5c header does not have the
// full leaf → intermediate → root chain Apple's real signing service emits.
// Xcode's local StoreKit environment ships a self-signed chain of length 1,
// which would otherwise trigger an index-out-of-range panic inside go-iap's
// cert parsing path.
func assertRealAppleChain(jws string) error {
	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		return errors.New("apple: malformed JWS (expected 3 segments)")
	}
	headerBytes, err := base64.RawStdEncoding.DecodeString(parts[0])
	if err != nil {
		// Some producers use URL-safe base64; retry.
		headerBytes, err = base64.RawURLEncoding.DecodeString(parts[0])
		if err != nil {
			return fmt.Errorf("apple: decode JWS header: %w", err)
		}
	}
	var header struct {
		X5c []string `json:"x5c"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return fmt.Errorf("apple: parse JWS header: %w", err)
	}
	if len(header.X5c) < 3 {
		return fmt.Errorf("apple: JWS x5c chain too short (%d certs) — not a production-signed transaction", len(header.X5c))
	}
	return nil
}

func msToTime(ms int64) time.Time {
	if ms == 0 {
		return time.Time{}
	}
	return time.UnixMilli(ms)
}
