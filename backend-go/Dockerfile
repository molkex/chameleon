# ============================================================================
# Chameleon VPN Backend — Multi-stage Docker build
# ============================================================================
# Stage 1: Build the Go binary (static, no CGO)
# Stage 2: Minimal Alpine runtime with non-root user
# ============================================================================

# --- Build stage ---
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git

WORKDIR /src

# Cache dependencies first (changes less frequently than source code).
COPY go.mod go.sum ./
RUN go mod download

# Copy source and build.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w -X main.version=$(git describe --tags --always --dirty 2>/dev/null || echo dev)" \
    -o /chameleon \
    ./cmd/chameleon

# --- Runtime stage ---
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata wget

# Non-root user for security.
RUN adduser -D -u 1000 chameleon

COPY --from=builder /chameleon /usr/local/bin/chameleon

# Drop all capabilities, run as non-root.
USER chameleon

EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD wget -qO- http://localhost:8000/health || exit 1

ENTRYPOINT ["chameleon"]
CMD ["--config", "/etc/chameleon/config.yaml"]
