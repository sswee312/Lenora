# lenora-adapter-openai

OpenAI adapter for lenora-backend: voiceover and prompt rewriting. OpenAI returns bytes or text, not URLs, so the results live in the core result store (`<LENORA_DATA_DIR>/results`, 24 hours) and are served from `GET /v1/results/{id}` with the backend token.

- **Voiceover is a background job.** A long script takes over a minute, so `POST /v1/jobs` returns `queued` at once and the adapter makes the OpenAI call in its own task: at most 4 at once, at most 32 queued or running (more is `rate_limited`). Poll `GET /v1/jobs/{id}` until it is terminal; `DELETE /v1/jobs/{id}` cancels it (a queued job is refunded). Each call is capped at 300 s. In-flight jobs live in memory: if the backend restarts while one runs, polling it reports `failed` (`provider_unavailable`, retryable). A finished voiceover is found from its job ID after a restart.
- **Prompt rewriting is synchronous:** the job is `succeeded` on its first poll and cannot be cancelled.

| Model | Kind | Notes |
|---|---|---|
| `openai/voice` | `audio.speech` | `gpt-4o-mini-tts`. Script up to 4096 characters; 13 voices (default `alloy`); optional style instructions; mp3 or wav. Estimate 0.0175 USD per 1000 characters. |
| `openai/rewrite` | `text.rewritePrompt` | `gpt-5.4-mini` through `/responses`. Targets `video.generate`, `image.generate`, `audio.speech`, `image.edit`; the result always fits the target's prompt rules. Estimate 0.0104 USD per call. |

## Settings

| Variable | Default |
|---|---|
| `LENORA_OPENAI_API_KEY`, else `OPENAI_API_KEY` | — (the adapter is disabled without one) |
| `LENORA_OPENAI_DAILY_BUDGET_USD` | `5.0`; `0` means no cap |
| `LENORA_OPENAI_SPEECH_MODEL` | `gpt-4o-mini-tts` |
| `LENORA_OPENAI_REWRITE_MODEL` | `gpt-5.4-mini` |

The daily budget counts estimates, not OpenAI's bill. A request that provably never reached OpenAI, a voiceover cancelled while still queued, or a request OpenAI refused is refunded; a timeout after sending, or a cancellation once the call started, is not.

At start, and on `GET /v1/health?recheck=addons`, the adapter looks up the speech model once. A rejected key hides both models; a missing speech model hides `openai/voice`. Health shows the result under `addons`.

Job IDs are signed with `<LENORA_DATA_DIR>/openai.key`, a random key created on first use (mode 0600). Deleting it invalidates outstanding job IDs.

## Test

```bash
uv run pytest adapters/openai/tests                       # mocked
uv run --env-file ../.env pytest -m live -q adapters/openai/tests/test_openai_live.py   # about $0.02
```
