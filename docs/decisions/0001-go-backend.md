---
title: Go backend (replaces Rust)
date: 2026-04-15
status: active
tags: [backend, go, architecture]
---

# 0001 — Go backend

## Context

The original Chameleon backend was written in Rust (in `backend/` legacy, retained as reference only). It worked, but:

- Build times slow.
- Idiomatic concurrency with Tokio harder to reason about than Go's goroutines for our scale.
- Smaller dependency tree in Go = less audit surface.
- Faster onboarding for any future contributor.

## Decision

Rewrite the backend in **Go** (1.25.x). New code under `backend/internal/`, binary `cmd/chameleon`. Rust kept frozen for reference (not deployed).

Framework: **Echo v4** (mature, fast, simple middleware story).
DB: **pgx/v5 pool** directly (no ORM).
Redis: **go-redis/v9**.
Logging: **uber-go/zap**.
Tests: stdlib `testing` + `testcontainers-go` for Postgres.

## Consequences

- Build + deploy went from minutes to ~30s.
- All new features (USR-*, MON-*, MED-*, BE-*) implemented Go-first.
- Memory: ~80 MB resident vs Rust ~120 MB. Acceptable on Timeweb 2GB box.
- Loss: we re-implemented some Rust-only crates (no `actix-cors` analog, but `echo-contrib` works).

## Status

Active. No plans to revisit. If we ever need Rust-level performance for a specific path, write a sidecar binary.
