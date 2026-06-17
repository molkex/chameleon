package mobile

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// RegisterRequest is the body for POST /api/mobile/auth/register.
//
// MED-012 (2026-05-27): `InstallSecret` is the server-issued credential
// that pairs with `DeviceID`. New iOS builds receive it on first register
// and echo it on every subsequent call. Legacy builds (75-89, currently
// in the field) omit it — Phase-1 backward-compat accepts that and
// generates a fresh secret on those calls. Once iOS adoption crosses
// ~95%, Phase 2 flips to strict-require (reject when DB has a secret
// stored but client sends none/wrong).
type RegisterRequest struct {
	DeviceID       string `json:"device_id"`
	InstallSecret  string `json:"install_secret,omitempty"`
}

// AppleSignInRequest is the body for POST /api/mobile/auth/apple.
type AppleSignInRequest struct {
	IdentityToken string `json:"identity_token"`
	DeviceID      string `json:"device_id"`
}

// AuthResponse is the response for successful authentication.
//
// MED-012: `InstallSecret` is populated on every successful register.
// Clients MUST persist it to Keychain and present it on subsequent
// registers — see RegisterRequest.InstallSecret.
type AuthResponse struct {
	AccessToken   string `json:"access_token"`
	RefreshToken  string `json:"refresh_token"`
	ExpiresAt     int64  `json:"expires_at"`
	UserID        int64  `json:"user_id"`
	Username      string `json:"username"`
	IsNew         bool   `json:"is_new"`
	InstallSecret string `json:"install_secret,omitempty"`
}

// ErrorResponse is the standard JSON error body.
type ErrorResponse struct {
	Error string `json:"error"`
	// Code is an optional machine-readable error code so the client can branch
	// without string-matching the human-readable Error. e.g. EXPIRED-PAYWALL
	// (2026-06-17): a /config 403 carries Code="SUBSCRIPTION_EXPIRED" so the app
	// can route an expired user straight to the paywall on a connect attempt.
	Code string `json:"code,omitempty"`
}

// CodeSubscriptionExpired is the machine-readable code on the /config 403 when
// the user's subscription is absent or in the past — the client's signal to
// show the paywall (EXPIRED-PAYWALL-ON-CONNECT).
const CodeSubscriptionExpired = "SUBSCRIPTION_EXPIRED"

// hasActiveSubscription is the ONE canonical "is this user's subscription
// currently active?" predicate. subscription_expiry == NULL means NO coverage
// (never subscribed / refunded-to-zero) — NOT "lifetime" — consistent with
// shouldGrantTrial and credit.go's revoke path. A user is covered only by a
// future expiry timestamp. Centralised so the /config gate, the VPN roster
// (db.ListActiveVPNUsers) and the trial gate can't drift apart again.
func hasActiveSubscription(u *db.User) bool {
	return u.SubscriptionExpiry != nil && u.SubscriptionExpiry.After(time.Now())
}

// Register handles POST /api/mobile/auth/register.
//
// It finds or creates a user by device_id, generates VPN credentials if needed,
// adds the user to the VPN engine, and returns a JWT token pair.
func (h *Handler) Register(c echo.Context) error {
	var req RegisterRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}

	req.DeviceID = strings.TrimSpace(req.DeviceID)
	if req.DeviceID == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "device_id is required"})
	}
	if len(req.DeviceID) > 256 {
		// Real iOS identifierForVendor is a 36-char UUID; anything longer
		// is hostile input. Cap before it reaches the DB or sha256.
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "device_id too long"})
	}

	ctx := c.Request().Context()

	// Look up existing user.
	user, err := h.DB.FindUserByDeviceID(ctx, req.DeviceID)
	if err != nil {
		h.Logger.Error("db: find user by device_id", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	isNew := false

	if user == nil {
		// New user — generate VPN credentials and create.
		isNew = true
		user, err = h.createUser(ctx, req.DeviceID, "", "device")
		if err != nil {
			h.Logger.Error("create device user", zap.Error(err), zap.String("device_id", req.DeviceID))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}

		h.Logger.Info("new user registered",
			zap.Int64("user_id", user.ID),
			zap.String("device_id", req.DeviceID),
		)
		if h.Metrics != nil {
			h.Metrics.CountSignup("device")
		}
	} else {
		h.Logger.Info("existing user login",
			zap.Int64("user_id", user.ID),
			zap.String("device_id", req.DeviceID),
		)
	}

	// MED-012 install_secret pairing:
	//   - If user.InstallSecret is set AND client sent a value that does
	//     NOT match → reject. This is the actual hijack defense: an
	//     attacker who guessed/stole a device_id but doesn't have the
	//     paired secret can't impersonate the user.
	//   - If user.InstallSecret is set AND client sent the matching
	//     value → accept, no rotation.
	//   - If user.InstallSecret is set AND client sent nothing → accept
	//     (Phase-1 backward-compat for legacy iOS builds 75-89 in the
	//     field), do not rotate. Phase 2 will flip this to reject.
	//   - If user.InstallSecret is NULL → first time we see this
	//     device_id pair. Generate a fresh secret, store it, return to
	//     client. Whether the request supplied one or not is irrelevant
	//     because there's nothing in the DB to compare against yet.
	//
	// The returned secret is always populated in the response body so
	// every register call is a chance for a new iOS build to grab and
	// persist its secret.
	issuedSecret := ""
	if user.InstallSecret != nil && *user.InstallSecret != "" {
		if req.InstallSecret != "" && req.InstallSecret != *user.InstallSecret {
			h.Logger.Warn("install_secret mismatch — possible hijack attempt",
				zap.Int64("user_id", user.ID),
				zap.String("device_id", req.DeviceID),
				zap.String("ip", c.RealIP()),
			)
			return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "invalid credentials"})
		}
		issuedSecret = *user.InstallSecret
	} else {
		secret, err := generateInstallSecret()
		if err != nil {
			h.Logger.Error("generate install_secret", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		if err := h.DB.UpdateInstallSecret(ctx, user.ID, secret); err != nil {
			h.Logger.Error("store install_secret", zap.Error(err), zap.Int64("user_id", user.ID))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		issuedSecret = secret
	}

	// Add user to VPN engine (idempotent — safe for existing users too).
	if err := h.addUserToVPN(ctx, user); err != nil {
		h.Logger.Warn("vpn: add user (non-fatal)", zap.Error(err), zap.Int64("user_id", user.ID))
		// Non-fatal: user can still get their token; VPN will sync later.
	}

	// Snapshot signup-time country. Runs only for brand-new users so the
	// first IP we see — before they ever connect to our VPN — is the one
	// we geolocate. For returning logins it's a no-op.
	if isNew {
		h.captureInitialContext(c, user.ID)
	}

	// Issue token pair.
	vpnUsername := ""
	if user.VPNUsername != nil {
		vpnUsername = *user.VPNUsername
	}
	tokens, err := h.JWT.CreateTokenPair(user.ID, vpnUsername, "user")
	if err != nil {
		h.Logger.Error("jwt: create token pair", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	return c.JSON(http.StatusOK, AuthResponse{
		AccessToken:   tokens.AccessToken,
		RefreshToken:  tokens.RefreshToken,
		ExpiresAt:     tokens.ExpiresAt,
		UserID:        user.ID,
		Username:      vpnUsername,
		IsNew:         isNew,
		InstallSecret: issuedSecret,
	})
}

// generateInstallSecret returns a 32-byte hex-encoded random string
// (64 chars) for use as the server-issued client credential. MED-012:
// crypto/rand is the entropy source — never math/rand, which is
// predictable. Length matches install_secret column in
// 016_install_secret.sql.
func generateInstallSecret() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generate install_secret: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// captureInitialContext geolocates the request IP and stores it in the
// user's initial_* columns. Runs in a detached goroutine so it never slows
// the registration response. SaveInitialContext guards against overwriting
// already-populated values, so multiple callers are safe.
func (h *Handler) captureInitialContext(c echo.Context, userID int64) {
	ip := c.RealIP()
	req := c.Request()

	var installDate *time.Time
	if s := strings.TrimSpace(req.Header.Get("X-Install-Date")); s != "" {
		if t, err := time.Parse("2006-01-02", s); err == nil {
			installDate = &t
		}
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		snap := db.InitialContext{IP: ip, InstallDate: installDate}
		if h.GeoIP != nil && ip != "" {
			geo := h.GeoIP.Lookup(ctx, ip)
			snap.Country = geo.Country
			snap.CountryName = geo.CountryName
			snap.City = geo.City
		}
		if err := h.DB.SaveInitialContext(ctx, userID, snap); err != nil {
			h.Logger.Warn("save initial context", zap.Error(err), zap.Int64("user_id", userID))
		}
	}()
}

// AppleSignIn handles POST /api/mobile/auth/apple.
//
// It verifies the Apple identity token, finds or creates a user by apple_id,
// links the device_id, and returns a JWT token pair.
func (h *Handler) AppleSignIn(c echo.Context) error {
	var req AppleSignInRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}

	req.IdentityToken = strings.TrimSpace(req.IdentityToken)
	req.DeviceID = strings.TrimSpace(req.DeviceID)

	if req.IdentityToken == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "identity_token is required"})
	}
	if req.DeviceID == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "device_id is required"})
	}

	ctx := c.Request().Context()

	// Verify the Apple identity token.
	appleClaims, err := h.Apple.VerifyAndExtract(ctx, req.IdentityToken)
	if err != nil {
		h.Logger.Warn("apple: verify identity token", zap.Error(err))
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "invalid apple identity token"})
	}
	appleID := appleClaims.Sub

	// Look up existing user by apple_id.
	user, err := h.DB.FindUserByAppleID(ctx, appleID)
	if err != nil {
		h.Logger.Error("db: find user by apple_id", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	// Fall back to device_id — the user may have first tapped "Continue
	// without account" on this device, creating a row with this device_id.
	// We must reuse THAT row, otherwise createUser would collide on
	// UNIQUE(device_id) against the guest user that already owns it.
	if user == nil {
		existingByDevice, err := h.DB.FindUserByDeviceID(ctx, req.DeviceID)
		if err != nil {
			h.Logger.Error("db: find user by device_id", zap.Error(err))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}
		if existingByDevice != nil {
			// Promote the guest/anon user to a Sign-in-with-Apple identity by
			// stamping apple_id on it. Treat as existing-user path below so
			// IsActive / device_id / vpn-creds are reconciled properly.
			existingByDevice.AppleID = &appleID
			provider := "apple"
			existingByDevice.AuthProvider = &provider
			user = existingByDevice
		}
	}

	isNew := false

	if user == nil {
		// New user — create with Apple ID and device_id.
		isNew = true
		user, err = h.createUser(ctx, req.DeviceID, appleID, "apple")
		if err != nil {
			h.Logger.Error("create apple user", zap.Error(err), zap.String("apple_id", appleID))
			return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
		}

		h.Logger.Info("new apple user registered",
			zap.Int64("user_id", user.ID),
			zap.String("apple_id", appleID),
		)
		if h.Metrics != nil {
			h.Metrics.CountSignup("apple")
		}
	} else {
		// Existing user — reactivate if previously soft-deleted, and update
		// device_id if changed. Reactivation on Sign-in is the standard soft-
		// delete pattern: the user explicitly asked to come back, so we grant
		// access again (their row was retained for audit/receipt replay).
		dirty := false
		if !user.IsActive {
			user.IsActive = true
			dirty = true
			h.Logger.Info("reactivating soft-deleted apple user",
				zap.Int64("user_id", user.ID),
				zap.String("apple_id", appleID),
			)
		}
		// Wiped users (option B delete) come back with NULL VPN creds.
		// Regenerate so they can connect again — subscription stays wiped
		// until they Restore Purchases.
		if user.VPNUsername == nil || user.VPNUUID == nil {
			vpnUUID, err := generateUUID()
			if err != nil {
				h.Logger.Error("regen vpn uuid", zap.Error(err))
				return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
			}
			vpnUsername := generateVPNUsernameFromUUID(vpnUUID)
			vpnShortID := ""
			user.VPNUsername = &vpnUsername
			user.VPNUUID = &vpnUUID
			user.VPNShortID = &vpnShortID
			dirty = true
			h.Logger.Info("regenerated vpn creds for returning user",
				zap.Int64("user_id", user.ID),
				zap.String("vpn_username", vpnUsername),
			)
		}
		if user.DeviceID == nil || *user.DeviceID != req.DeviceID {
			// Free up the new device_id if currently held by a different user
			// (transient guest from this install). Without this, UPDATE
			// collides on UNIQUE(device_id).
			other, ferr := h.DB.FindUserByDeviceID(ctx, req.DeviceID)
			if ferr != nil {
				h.Logger.Error("apple: find conflicting device_id", zap.Error(ferr))
				return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
			}
			if other != nil && other.ID != user.ID {
				h.Logger.Info("apple: freeing device_id from conflicting user",
					zap.Int64("conflicting_user_id", other.ID),
					zap.Int64("claiming_user_id", user.ID))
				if err := h.DB.ClearDeviceID(ctx, other.ID); err != nil {
					h.Logger.Error("apple: clear conflicting device_id", zap.Error(err))
					return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
				}
			}
			user.DeviceID = &req.DeviceID
			dirty = true
		}
		// SEC-01 (2026-06-01): grant the trial at most ONCE per identity.
		// Previously we re-extended the trial on EVERY expired-sub sign-in,
		// which let any apple_id harvest a fresh 3-day trial indefinitely.
		// trial_granted_at is the permanent per-identity gate (mirrors Apple's
		// isEligibleForIntroOffer: eligible→ineligible, never back). A
		// returning user whose trial already lapsed gets nothing here and must
		// purchase/restore — iOS handles the resulting /config 403 gracefully
		// (signInWithApple treats it as "signed in, no active subscription").
		// Active payers are untouched: their SubscriptionExpiry is in the
		// future, so the guard never fires.
		if shouldGrantTrial(user) {
			trialDays := 3
			if h.Config != nil && h.Config.Payments.Trial.Enabled && h.Config.Payments.Trial.Days > 0 {
				trialDays = h.Config.Payments.Trial.Days
			}
			now := time.Now()
			newExpiry := now.Add(time.Duration(trialDays) * 24 * time.Hour)
			user.SubscriptionExpiry = &newExpiry
			user.TrialGrantedAt = &now
			dirty = true
			h.Logger.Info("apple: granting first-time trial on sign-in",
				zap.Int64("user_id", user.ID),
				zap.Time("new_expiry", newExpiry))
		}
		if dirty {
			if err := h.DB.UpdateUser(ctx, user); err != nil {
				h.Logger.Error("db: update user", zap.Error(err))
				return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
			}
		}

		h.Logger.Info("existing apple user login",
			zap.Int64("user_id", user.ID),
			zap.String("apple_id", appleID),
		)
	}

	// Add user to VPN engine.
	if err := h.addUserToVPN(ctx, user); err != nil {
		h.Logger.Warn("vpn: add user (non-fatal)", zap.Error(err), zap.Int64("user_id", user.ID))
	}

	// Snapshot signup-time country on first Apple sign-in.
	if isNew {
		h.captureInitialContext(c, user.ID)
	}

	// Persist Apple-provided email (once, on first sign-in) so the user has
	// a recoverable identity beyond their Apple account. Apple only sends
	// email on the very first sign-in; after that the field is empty, so we
	// only write if missing.
	if appleClaims.Email != "" && (user.Email == nil || *user.Email == "") {
		if err := h.DB.SetUserEmail(ctx, user.ID, appleClaims.Email); err != nil {
			h.Logger.Warn("apple: set email (non-fatal)", zap.Error(err))
		} else {
			e := appleClaims.Email
			user.Email = &e
			// Apple has already verified the email for us.
			_ = h.DB.MarkEmailVerified(ctx, user.ID)
		}
		// NOTE: we used to fire a "backup magic link" email here on first
		// Apple sign-in. Removed 2026-05-29: across 204 issued backup links
		// (Apple+Google) exactly 0 were ever used, yet they burned ~84% of
		// the Resend daily quota — most went to @privaterelay.appleid.com
		// relay addresses the user never checks. The user already has Apple
		// Sign-In as their primary path; if we want an opt-in email fallback
		// later, trigger it from an explicit in-app action, not on every
		// signup. See docs/incidents/2026-05-29-resend-quota.md.
	}

	// Issue token pair.
	vpnUsername := ""
	if user.VPNUsername != nil {
		vpnUsername = *user.VPNUsername
	}
	tokens, err := h.JWT.CreateTokenPair(user.ID, vpnUsername, "user")
	if err != nil {
		h.Logger.Error("jwt: create token pair", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	return c.JSON(http.StatusOK, AuthResponse{
		AccessToken:  tokens.AccessToken,
		RefreshToken: tokens.RefreshToken,
		ExpiresAt:    tokens.ExpiresAt,
		UserID:       user.ID,
		Username:     vpnUsername,
		IsNew:        isNew,
	})
}

// RefreshToken handles POST /api/mobile/auth/refresh.
//
// Verifies the refresh token and issues a new access+refresh token pair.
// Each refresh token is single-use: once consumed, it is blacklisted in Redis.
func (h *Handler) RefreshToken(c echo.Context) error {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "invalid request body"})
	}
	if req.RefreshToken == "" {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "refresh_token is required"})
	}

	claims, err := h.JWT.VerifyRefreshToken(req.RefreshToken)
	if err != nil {
		h.Logger.Warn("mobile refresh: invalid token", zap.Error(err))
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "invalid refresh token"})
	}

	// One-time use: mark this token as used in Redis (same pattern as admin auth).
	// SET NX ensures only the first caller succeeds.
	ctx := c.Request().Context()
	// Audit H-007 (2026-05-26): SHA-256 of full token, not 32-char prefix.
	// HS256 JWT headers share a stable prefix, so token[:32] could collide
	// across unrelated refresh tokens.
	rtHash := sha256.Sum256([]byte(req.RefreshToken))
	key := fmt.Sprintf("mrt:used:%s", hex.EncodeToString(rtHash[:]))
	ttl := 30 * 24 * time.Hour // Keep blacklist entry for 30 days

	// SetArgs with Mode:"NX" is the non-deprecated replacement for SetNX
	// (as of Redis 2.6.12 / go-redis v9). On condition-failed Redis returns
	// (nil), which surfaces as redis.Nil in go-redis.
	if _, serr := h.Redis.SetArgs(ctx, key, "1", redis.SetArgs{Mode: "NX", TTL: ttl}).Result(); serr != nil {
		if errors.Is(serr, redis.Nil) {
			h.Logger.Warn("mobile refresh: token reuse attempt", zap.Int64("user_id", claims.UserID))
			return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "refresh token already used"})
		}
		h.Logger.Error("mobile refresh: redis error", zap.Error(serr))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	tokens, err := h.JWT.CreateTokenPair(claims.UserID, claims.Username, claims.Role)
	if err != nil {
		h.Logger.Error("mobile refresh: create token pair", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
	}

	return c.JSON(http.StatusOK, AuthResponse{
		AccessToken:  tokens.AccessToken,
		RefreshToken: tokens.RefreshToken,
		ExpiresAt:    tokens.ExpiresAt,
		UserID:       claims.UserID,
		Username:     claims.Username,
	})
}

// createUser creates a new user with VPN credentials and a 30-day trial subscription.
// deviceID is always required; appleID and authProvider vary by sign-in method.
func (h *Handler) createUser(ctx context.Context, deviceID, appleID, authProvider string) (*db.User, error) {
	vpnUUID, err := generateUUID()
	if err != nil {
		return nil, fmt.Errorf("generate uuid: %w", err)
	}
	vpnUsername := generateVPNUsernameFromUUID(vpnUUID)
	// Use empty short_id — it is always valid in sing-box Reality config.
	// Random short_ids caused "reality verification failed" because they
	// weren't in the server's allowed short_id list.
	vpnShortID := ""

	trialDays := 3
	if h.Config != nil && h.Config.Payments.Trial.Enabled && h.Config.Payments.Trial.Days > 0 {
		trialDays = h.Config.Payments.Trial.Days
	}
	// SEC-01 (2026-06-01): this is the single trial grant for a brand-new
	// identity. Stamp trial_granted_at so a later expired-sub sign-in can't
	// hand out a second trial (see the grant-once guard in AppleSignIn /
	// GoogleSignIn).
	trialStart := time.Now()
	trialExpiry := trialStart.Add(time.Duration(trialDays) * 24 * time.Hour)

	user := &db.User{
		DeviceID:           &deviceID,
		VPNUsername:         &vpnUsername,
		VPNUUID:            &vpnUUID,
		VPNShortID:         &vpnShortID,
		IsActive:           true,
		SubscriptionExpiry: &trialExpiry,
		TrialGrantedAt:     &trialStart,
		AuthProvider:       &authProvider,
	}

	if appleID != "" {
		user.AppleID = &appleID
	}

	if err := h.DB.CreateUser(ctx, user); err != nil {
		return nil, fmt.Errorf("db create user: %w", err)
	}

	return user, nil
}

// addUserToVPN adds a user to the VPN engine if the engine is available and the user has credentials.
func (h *Handler) addUserToVPN(ctx context.Context, user *db.User) error {
	if h.VPN == nil {
		return nil // VPN engine not configured, skip.
	}
	if user.VPNUsername == nil || user.VPNUUID == nil {
		return nil // No VPN credentials, skip.
	}

	shortID := ""
	if user.VPNShortID != nil {
		shortID = *user.VPNShortID
	}

	return h.VPN.AddUser(ctx, vpn.VPNUser{
		Username: *user.VPNUsername,
		UUID:     *user.VPNUUID,
		ShortID:  shortID,
	})
}

// shouldGrantTrial reports whether a free trial should be granted to this
// user on sign-in. SEC-01 (2026-06-01): a trial is granted at most ONCE per
// identity, so the gate is `trial_granted_at IS NULL` — NOT subscription_expiry
// (which an admin/support action can legitimately clear, and which used to let
// an expired user harvest a new trial on every re-authentication). The
// expiry check is secondary: a still-active subscriber never needs a trial.
func shouldGrantTrial(u *db.User) bool {
	if u.TrialGrantedAt != nil {
		return false
	}
	return u.SubscriptionExpiry == nil || u.SubscriptionExpiry.Before(time.Now())
}

// generateVPNUsername creates a VPN username derived from the user's
// per-registration vpn_uuid (NOT device_id). Using device_id meant that two
// users sharing a device — re-register after delete, or two installs of the
// app on the same hardware — produced the same username, which collides
// with the unique idx_users_vpn_username DB index and rejects cluster sync
// upserts. Hashing the uuid keeps usernames stable per registration and
// guarantees uniqueness because uuids are crypto-random 128 bits.
func generateVPNUsernameFromUUID(uuid string) string {
	hash := sha256.Sum256([]byte(uuid))
	return "device_" + hex.EncodeToString(hash[:])[:8]
}

// generateUUID generates a random UUID v4 using crypto/rand.
func generateUUID() (string, error) {
	var uuid [16]byte
	if _, err := rand.Read(uuid[:]); err != nil {
		return "", fmt.Errorf("crypto/rand: %w", err)
	}

	// Set version (4) and variant (RFC 4122) bits.
	uuid[6] = (uuid[6] & 0x0f) | 0x40 // version 4
	uuid[8] = (uuid[8] & 0x3f) | 0x80 // variant 10

	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		uuid[0:4], uuid[4:6], uuid[6:8], uuid[8:10], uuid[10:16],
	), nil
}

// generateShortID generates a random 8-character hex string using crypto/rand.
func generateShortID() (string, error) {
	b := make([]byte, 4) // 4 bytes = 8 hex chars
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("crypto/rand: %w", err)
	}
	return hex.EncodeToString(b), nil
}
