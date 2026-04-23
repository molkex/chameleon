# Backend tests

Three layers, gated by build tags so a default `go test` only runs unit tests.

## Unit (default)
Live next to the code they test (`internal/*/*_test.go`). Pure logic, no I/O,
no external services. Currently:
- `internal/config/config_test.go`
- `internal/payments/freekassa/signature_test.go`

```sh
go test ./...
```

## Integration (build tag `integration`)
Live in `tests/integration/`. Spin up real Postgres + Redis via
[testcontainers-go](https://golang.testcontainers.org/), exercise full HTTP
handlers with real DB queries.

```sh
go test -tags=integration ./tests/integration/...
```

Requires Docker running locally.

## E2E (build tag `e2e`)
Live in `tests/e2e/`. Generate real sing-box client configs and validate
them with `sing-box check`. Catches sing-box schema drift before it lands
on a device.

```sh
go test -tags=e2e ./tests/e2e/...
```

Requires `sing-box` in PATH (`curl -fsSL https://sing-box.app/install.sh | sh`).

## CI
- `unit` runs on every PR (`.github/workflows/backend.yml` job: `unit`)
- `integration` runs on every PR (job: `integration`) — Docker is preinstalled on GitHub runners
- `e2e` runs on every PR (job: `e2e`) — sing-box installed in the workflow

## Coverage targets
- Unit: 70% of `internal/`
- Integration: every HTTP endpoint hit at least once (happy path + main errors)
- E2E: every change to `internal/vpn/clientconfig.go` or `migrations/` triggers it
