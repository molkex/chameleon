// Package cli provides command-line utilities for Chameleon VPN backend administration.
//
// These commands are used for initial setup and maintenance tasks that should
// not be exposed via the HTTP API (e.g., creating the first admin user).
package cli

import (
	"context"
	"fmt"
	"time"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
)

// CreateAdmin creates an admin user in the database.
//
// This is the recommended way to create the first admin user after deployment.
// Usage: chameleon admin create --username admin --password xxx --role admin
//
// Supported roles: "admin", "operator".
func CreateAdmin(dbURL, username, password, role string) error {
	if username == "" {
		return fmt.Errorf("username is required")
	}
	if password == "" {
		return fmt.Errorf("password is required")
	}
	if role == "" {
		role = "admin"
	}
	if role != "admin" && role != "operator" {
		return fmt.Errorf("invalid role %q: must be 'admin' or 'operator'", role)
	}

	// Hash password with argon2id.
	hash, err := auth.HashPassword(password)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}

	// Connect to database.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	database, err := db.New(ctx, dbURL, 5, 1, time.Minute)
	if err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}
	defer database.Close()

	// Check if username already exists.
	existing, err := database.FindAdminByUsername(ctx, username)
	if err != nil {
		return fmt.Errorf("check existing admin: %w", err)
	}
	if existing != nil {
		return fmt.Errorf("admin user %q already exists (id=%d)", username, existing.ID)
	}

	// Create admin.
	admin, err := database.CreateAdmin(ctx, username, hash, role)
	if err != nil {
		return fmt.Errorf("create admin: %w", err)
	}

	fmt.Printf("Admin user created successfully:\n")
	fmt.Printf("  ID:       %d\n", admin.ID)
	fmt.Printf("  Username: %s\n", admin.Username)
	fmt.Printf("  Role:     %s\n", admin.Role)

	return nil
}
