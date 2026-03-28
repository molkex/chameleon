# Contributing to Chameleon VPN

Thank you for your interest in contributing. This guide covers development setup, code standards, and the PR process.

## Development Setup

### Prerequisites

- Python 3.11+
- Node.js 20+ (for admin SPA)
- PostgreSQL 16+
- Redis 7+
- Docker (optional, for integration tests)

### Backend

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"

# Copy and configure environment
cp ../.env.example ../.env

# Run linters
ruff check app/
mypy app/

# Run tests
pytest
```

### Admin SPA

```bash
cd admin
npm install
npm run dev      # development server
npm run build    # production build
```

## Code Style

### Python

We use **ruff** for linting/formatting and **mypy** for type checking.

```bash
# Lint
ruff check app/

# Format
ruff format app/

# Type check
mypy app/
```

Configuration is in `pyproject.toml`:

- Target: Python 3.11
- Line length: 120
- Rules: E, F, I (isort), N (naming), UP (pyupgrade)

### TypeScript / React

- TailwindCSS v4 for styling
- shadcn/ui for components
- TanStack Router for routing (type-safe)

## Pull Request Process

1. **Fork** the repository and create a feature branch from `main`.
2. **Write tests** for new functionality. Run the full test suite before submitting.
3. **Lint and type-check** your code -- CI will reject PRs with lint errors.
4. **Keep PRs focused** -- one feature or fix per PR.
5. **Write a clear description** explaining what the PR does and why.
6. **Update documentation** if your change affects the API, configuration, or architecture.

### Commit Messages

Use conventional-style messages:

```
feat: add ShadowTLS protocol plugin
fix: correct SNI rotation health check logic
docs: update API endpoint table
refactor: extract fallback chain into separate module
```

## Adding a New Protocol

Protocol plugins live in `backend/app/vpn/protocols/`. To add one:

1. **Create** `backend/app/vpn/protocols/your_protocol.py`
2. **Implement** the `ProtocolPlugin` ABC (see `base.py` for the interface)
   - `info` property -- metadata (name, display name, transport, port)
   - `generate_outbound()` -- sing-box outbound config dict
   - `generate_link()` -- subscription link string
   - `health_check()` (optional) -- custom health check logic
3. **Register** in `backend/app/vpn/protocols/__init__.py`
4. **Add tests** in `backend/tests/test_protocols/`

See existing plugins (`vless_reality.py`, `hysteria2.py`) as reference implementations.

## Testing

```bash
cd backend

# Run all tests
pytest

# Run with coverage
pytest --cov=app

# Run a specific test file
pytest tests/test_protocols/test_vless_reality.py

# Run async tests (auto mode configured in pyproject.toml)
pytest tests/test_vpn/
```

### Test Categories

- `tests/test_protocols/` -- protocol plugin unit tests
- `tests/test_vpn/` -- VPN core logic (engine, shield, fallback)
- `tests/test_api/` -- API endpoint integration tests
- `tests/test_auth/` -- authentication and RBAC tests

## Architecture Decisions

Before making significant changes, review `ARCHITECTURE.md` for context on design decisions and trade-offs. If your change introduces a new architectural pattern, update the document accordingly.

## Questions?

Open an issue or start a discussion on GitHub.
