# Architecture

- `components.yaml` — high-level module map across backend / iOS / fork /
  infra. Each component has `path`, `responsibility`, `consumes`,
  `produces`, `contracts`.
- **Topology lives at `infrastructure/topology.yaml`** (canonical, not in
  `docs/`). Servers, relays, chains. Don't duplicate.
- `mesh.md` — (was `docs/ARCHITECTURE_MESH.md`) topology diagrams that
  don't compress to YAML. Moved here on the 2026-05-13 docs reorg.
