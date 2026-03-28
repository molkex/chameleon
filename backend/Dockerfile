# ── Stage 1: Build ──
FROM rust:latest AS builder

RUN apt-get update && apt-get install -y protobuf-compiler && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Cache dependencies by copying manifests first
COPY Cargo.toml Cargo.lock ./
COPY crates/chameleon-config/Cargo.toml crates/chameleon-config/Cargo.toml
COPY crates/chameleon-db/Cargo.toml crates/chameleon-db/Cargo.toml
COPY crates/chameleon-auth/Cargo.toml crates/chameleon-auth/Cargo.toml
COPY crates/chameleon-vpn/Cargo.toml crates/chameleon-vpn/Cargo.toml
COPY crates/chameleon-core/Cargo.toml crates/chameleon-core/Cargo.toml
COPY crates/chameleon-monitoring/Cargo.toml crates/chameleon-monitoring/Cargo.toml
COPY crates/chameleon-admin/Cargo.toml crates/chameleon-admin/Cargo.toml
COPY crates/chameleon-apple/Cargo.toml crates/chameleon-apple/Cargo.toml
COPY crates/chameleon-server/Cargo.toml crates/chameleon-server/Cargo.toml

# Create dummy source files so cargo can resolve deps
RUN for dir in crates/*/src; do mkdir -p "$dir" && echo "" > "$dir/lib.rs"; done && \
    mkdir -p crates/chameleon-server/src && echo "fn main() {}" > crates/chameleon-server/src/main.rs

# Build deps only (cached layer)
RUN cargo build --release 2>/dev/null || true

# Copy actual source
COPY crates/ crates/
COPY migrations/ migrations/

# Build for real (sqlx offline mode — no DB needed at compile time)
ENV SQLX_OFFLINE=true
RUN touch crates/*/src/*.rs crates/chameleon-server/src/main.rs && \
    cargo build --release --bin chameleon-server

# ── Stage 2: Runtime (minimal, no Docker CLI) ──
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

# Non-root user
RUN groupadd -r chameleon && useradd -r -g chameleon -d /app chameleon

COPY --from=builder /app/target/release/chameleon-server /usr/local/bin/
COPY migrations/ /app/migrations/

WORKDIR /app
USER chameleon

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -sf http://127.0.0.1:8000/health || exit 1

ENTRYPOINT ["chameleon-server"]
