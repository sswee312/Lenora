# lenora-backend

The reference backend for the [Lenora Backend Protocol](../protocol/README.md). FastAPI core, plus adapters discovered through the `lenora.adapters` entry-point group.

## Run locally

```bash
uv sync
uv run lenora-backend          # reads ../.env in development
```

`LENORA_ENV=development` (default) reads `.env`, binds `127.0.0.1:8787` and serves `/docs`. `LENORA_ENV=production` reads only the process environment, binds `0.0.0.0:$PORT`, logs JSON and has no `/docs`. Both refuse to start without `LENORA_TOKEN`.

## Configuration

| Variable | Required | Default |
|---|---|---|
| `LENORA_TOKEN` | yes | — |
| `LENORA_ENV` | no | `development` |
| `PORT` / `LENORA_PORT` | production | 8787 in development |
| `LENORA_PROVIDER_TIMEOUT_SECONDS` | no | 60 |
| `LENORA_CLOUDINARY_CLOUD_NAME`, `_API_KEY`, `_API_SECRET` | to enable Cloudinary | — |
| `LENORA_CLOUDINARY_ON_THE_FLY_VIDEO_MAX_BYTES` | no | 41943040 |
| `LENORA_CLOUDINARY_IMAGE_GENERATION`, `_IMAGE_TO_VIDEO` | no | `auto` |
| `LENORA_DATA_DIR` | no | `.data` |
| `LENORA_CLOUDINARY_DAILY_CREDIT_BUDGET` | no | unlimited |
| `LENORA_CLOUDINARY_COST_IMAGE_GENERATION`, `_COST_IMAGE_TO_VIDEO_PER_SECOND` | no | `1.0` |

An adapter with missing settings is disabled. `GET /v1/health` (with the token) shows why.

## Deploy

`docker build -t lenora-backend backend` and run it with `LENORA_TOKEN` and the adapter keys in the platform's environment. Idempotency keys live in memory, so run a single instance. Mount a volume at `/data` to keep chain jobs and learned add-on state across restarts.

## Write an adapter

Copy `adapters/_template` and follow its README. `lenora_backend.testing.conformance.AdapterConformance` checks your adapter against the protocol rules.

## Test

```bash
uv run pytest                 # unit, contract, conformance (mocked)
uv run pytest -m live         # real providers; needs keys
```
