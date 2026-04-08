package mobile

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// RegisterRequest is the body for POST /api/mobile/auth/register.
type RegisterRequest struct {
	DeviceID string `json:"device_id"`
}

// AppleSignInRequest is the body for POST /api/mobile/auth/apple.
type AppleSignInRequest struct {
	IdentityToken string `json:"identity_token"`
	DeviceID      string `json:"device_id"`
}

// AuthResponse is the response for successful authentication.
type AuthResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresAt    int64  `json:"expires_at"`
	UserID       int64  `json:"user_id"`
	IsNew        bool   `json:"is_new"`
}

// ErrorResponse is the standard JSON error body.
type ErrorResponse struct {
	Error string `json:"error"`
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
	} else {
		h.Logger.Info("existing user login",
			zap.Int64("user_id", user.ID),
			zap.String("device_id", req.DeviceID),
		)
	}

	// Add user to VPN engine (idempotent — safe for existing users too).
	if err := h.addUserToVPN(ctx, user); err != nil {
		h.Logger.Warn("vpn: add user (non-fatal)", zap.Error(err), zap.Int64("user_id", user.ID))
		// Non-fatal: user can still get their token; VPN will sync later.
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
		IsNew:        isNew,
	})
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
	appleID, err := h.Apple.VerifyIdentityToken(ctx, req.IdentityToken)
	if err != nil {
		h.Logger.Warn("apple: verify identity token", zap.Error(err))
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "invalid apple identity token"})
	}

	// Look up existing user by apple_id.
	user, err := h.DB.FindUserByAppleID(ctx, appleID)
	if err != nil {
		h.Logger.Error("db: find user by apple_id", zap.Error(err))
		return c.JSON(http.StatusInternalServerError, ErrorResponse{Error: "internal server error"})
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
	} else {
		// Existing user — update device_id if changed.
		if user.DeviceID == nil || *user.DeviceID != req.DeviceID {
			user.DeviceID = &req.DeviceID
			if err := h.DB.UpdateUser(ctx, user); err != nil {
				h.Logger.Error("db: update user device_id", zap.Error(err))
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
		IsNew:        isNew,
	})
}

// createUser creates a new user with VPN credentials and a 30-day trial subscription.
// deviceID is always required; appleID and authProvider vary by sign-in method.
func (h *Handler) createUser(ctx context.Context, deviceID, appleID, authProvider string) (*db.User, error) {
	vpnUsername := generateVPNUsername(deviceID)
	vpnUUID, err := generateUUID()
	if err != nil {
		return nil, fmt.Errorf("generate uuid: %w", err)
	}
	vpnShortID, err := generateShortID()
	if err != nil {
		return nil, fmt.Errorf("generate short_id: %w", err)
	}

	trialExpiry := time.Now().Add(30 * 24 * time.Hour)

	user := &db.User{
		DeviceID:           &deviceID,
		VPNUsername:         &vpnUsername,
		VPNUUID:            &vpnUUID,
		VPNShortID:         &vpnShortID,
		IsActive:           true,
		SubscriptionExpiry: &trialExpiry,
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

// generateVPNUsername creates a VPN username from a device_id.
// Format: "device_" + first 8 chars of sha256(device_id).
func generateVPNUsername(deviceID string) string {
	hash := sha256.Sum256([]byte(deviceID))
	hexHash := hex.EncodeToString(hash[:])
	return "device_" + hexHash[:8]
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
