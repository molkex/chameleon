// Package auth provides JWT token management, password hashing, and
// role-based access control for the Chameleon VPN backend.
//
// Sub-components:
//   - jwt.go: JWTManager — access/refresh token creation and verification
//   - password.go: argon2id hashing with bcrypt/SHA-256 legacy support
//   - middleware.go: Echo middleware for RequireAuth / RequireAdmin
//   - apple.go: Apple Sign-In identity token verification
package auth
