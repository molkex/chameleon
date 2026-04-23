# Admin SPA tests

## Unit (vitest — to wire up)

`tests/unit/` — vitest + `@testing-library/react` + MSW for API mocks.

To enable:

```sh
npm i -D vitest @vitest/ui @testing-library/react @testing-library/jest-dom \
  @testing-library/user-event jsdom msw
```

Add to `package.json` scripts:
```json
"test": "vitest run",
"test:watch": "vitest"
```

Add `vitest.config.ts` next to `vite.config.ts`. Then `npm test` will be
picked up by `.github/workflows/admin.yml` (already uses `npm test --if-present`).

Coverage target: 60% of `src/` (excluding `src/components/ui/` shadcn).

## E2E (Playwright — later)

`tests/e2e/` — Playwright for login, users CRUD, server CRUD, node sync.
Run only on `main` merges (slow).
