package auth

import (
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	issuer = "chameleon"

	// claimTokenType is the custom claim key that distinguishes refresh tokens.
	claimTokenType = "token_type"
	tokenTypeRefresh = "refresh"
)

// Claims represents JWT token claims for an authenticated user.
//
// TokenType is populated only on refresh tokens (value: "refresh"); access
// tokens leave it empty. parseToken() reads it so VerifyToken can reject a
// refresh token presented as an access token — a confused-deputy attack
// that would otherwise let a 30-day refresh credential bypass the 24-hour
// access TTL on every RequireAuth-protected route.
type Claims struct {
	UserID    int64  `json:"user_id"`
	Username  string `json:"username"`
	Role      string `json:"role,omitempty"`
	TokenType string `json:"token_type,omitempty"`
	jwt.RegisteredClaims
}

// TokenPair contains access + refresh tokens issued together.
type TokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresAt    int64  `json:"expires_at"` // unix timestamp of access token expiry
}

// JWTManager handles JWT token creation and verification.
type JWTManager struct {
	secret     []byte
	accessTTL  time.Duration
	refreshTTL time.Duration
}

// NewJWTManager creates a new JWT manager.
// Default TTLs: accessTTL=24h, refreshTTL=720h (30 days).
func NewJWTManager(secret string, accessTTL, refreshTTL time.Duration) *JWTManager {
	if accessTTL <= 0 {
		accessTTL = 24 * time.Hour
	}
	if refreshTTL <= 0 {
		refreshTTL = 720 * time.Hour
	}
	return &JWTManager{
		secret:     []byte(secret),
		accessTTL:  accessTTL,
		refreshTTL: refreshTTL,
	}
}

// CreateTokenPair generates an access + refresh token pair for the given user.
func (j *JWTManager) CreateTokenPair(userID int64, username, role string) (*TokenPair, error) {
	now := time.Now()

	// --- access token ---
	accessExp := now.Add(j.accessTTL)
	accessClaims := Claims{
		UserID:   userID,
		Username: username,
		Role:     role,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(accessExp),
		},
	}

	accessToken, err := jwt.NewWithClaims(jwt.SigningMethodHS256, accessClaims).SignedString(j.secret)
	if err != nil {
		return nil, fmt.Errorf("auth: sign access token: %w", err)
	}

	// --- refresh token ---
	refreshExp := now.Add(j.refreshTTL)
	refreshClaims := jwt.MapClaims{
		"user_id":    userID,
		"username":   username,
		"role":       role,
		claimTokenType: tokenTypeRefresh,
		"iss":        issuer,
		"iat":        jwt.NewNumericDate(now),
		"exp":        jwt.NewNumericDate(refreshExp),
	}

	refreshToken, err := jwt.NewWithClaims(jwt.SigningMethodHS256, refreshClaims).SignedString(j.secret)
	if err != nil {
		return nil, fmt.Errorf("auth: sign refresh token: %w", err)
	}

	return &TokenPair{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresAt:    accessExp.Unix(),
	}, nil
}

// VerifyToken validates a token string and returns the embedded claims.
// Refresh tokens (containing token_type=refresh) are rejected — use VerifyRefreshToken instead.
func (j *JWTManager) VerifyToken(tokenString string) (*Claims, error) {
	claims, err := j.parseToken(tokenString)
	if err != nil {
		return nil, err
	}
	return claims, nil
}

// VerifyRefreshToken validates a refresh token and returns the embedded claims.
// Only tokens with token_type=refresh are accepted.
func (j *JWTManager) VerifyRefreshToken(tokenString string) (*Claims, error) {
	// Parse as MapClaims first to check token_type.
	token, err := jwt.Parse(tokenString, j.keyFunc,
		jwt.WithIssuer(issuer),
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
	)
	if err != nil {
		return nil, fmt.Errorf("auth: invalid refresh token: %w", err)
	}

	mapClaims, ok := token.Claims.(jwt.MapClaims)
	if !ok || !token.Valid {
		return nil, fmt.Errorf("auth: invalid refresh token claims")
	}

	tt, _ := mapClaims[claimTokenType].(string)
	if tt != tokenTypeRefresh {
		return nil, fmt.Errorf("auth: token is not a refresh token")
	}

	// Extract structured claims.
	userID, _ := mapClaims["user_id"].(float64)
	username, _ := mapClaims["username"].(string)
	role, _ := mapClaims["role"].(string)

	return &Claims{
		UserID:   int64(userID),
		Username: username,
		Role:     role,
	}, nil
}

// parseToken is the internal parser for access tokens. It rejects any token
// carrying token_type=refresh — otherwise a 30-day refresh credential could
// be presented as a Bearer access token on every RequireAuth route.
func (j *JWTManager) parseToken(tokenString string) (*Claims, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, j.keyFunc,
		jwt.WithIssuer(issuer),
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
	)
	if err != nil {
		return nil, fmt.Errorf("auth: invalid token: %w", err)
	}
	if !token.Valid {
		return nil, fmt.Errorf("auth: token is not valid")
	}
	if claims.TokenType == tokenTypeRefresh {
		return nil, fmt.Errorf("auth: refresh token cannot be used as access token")
	}

	return claims, nil
}

// keyFunc returns the HMAC secret for token verification.
func (j *JWTManager) keyFunc(token *jwt.Token) (interface{}, error) {
	if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
		return nil, fmt.Errorf("auth: unexpected signing method: %v", token.Header["alg"])
	}
	return j.secret, nil
}
