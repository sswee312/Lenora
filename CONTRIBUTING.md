# Contributing

## Layout
- `app/` — Swift 6.2 editor. Read `app/AGENTS.md` before changing it: no main-thread file I/O, one undo step per user intent, `AppTheme` tokens, `L10n` copy, MCP end-to-end checks for tool changes.
- `backend/` — FastAPI core plus adapters. See `backend/README.md`.
- `protocol/` — the contract. Change `openapi.yaml` and `fixtures/` together; both sides test against them.

## Add a provider
Copy `backend/adapters/_template`, implement it, and make its conformance suite pass. The editor needs no change: models appear through `/v1/capabilities`.

## Checks
```bash
cd backend && uv run pytest
python3 scripts/rebrand.py --check --check-vendors
cd app && swift build && swift test
```

## Commits
`[category] Imperative summary`, for example `[fix] Prevent stale export completion`.
