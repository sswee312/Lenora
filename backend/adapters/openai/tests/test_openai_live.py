"""Real OpenAI calls, about $0.02 per run. Run only with the user's go-ahead:
  uv run --env-file ../.env pytest -m live -q adapters/openai/tests/test_openai_live.py
"""
import asyncio
import os

import httpx
import pytest

from oai import rewrite, speech
from lenora_backend.kinds import TERMINAL
from lenora_adapter_openai import OpenAIAdapter, OpenAISettings

POLL_SECONDS = 1
POLL_LIMIT = 120

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(not (os.environ.get("LENORA_OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY")),
                       reason="needs an OpenAI key"),
]


def live(scenario, tmp_path):
    async def go():
        async with httpx.AsyncClient(timeout=60) as http:
            adapter = OpenAIAdapter(OpenAISettings(data_dir=tmp_path), http)
            await adapter.start()
            try:
                return await scenario(adapter)
            finally:
                await adapter.stop()
    return asyncio.run(go())


def test_live_voiceover_is_audio(tmp_path):
    """Polls the background job the way the app does, until it is terminal."""
    async def scenario(a):
        job = await a.submit("openai/voice", speech("Welcome back.", voice="nova"))
        statuses = [job.status]
        for _ in range(POLL_LIMIT):
            state = await a.status(job.jobId)
            statuses.append(state.status)
            if state.status in TERMINAL:
                break
            await asyncio.sleep(POLL_SECONDS)
        assert state.status == "succeeded", state.error
        stored = await a.results.open(state.results[0].url.path.lstrip("/"))
        return statuses, stored.content_type, stored.path.read_bytes()
    statuses, content_type, data = live(scenario, tmp_path)
    assert statuses[0] == "queued" and statuses[-1] == "succeeded"
    assert content_type == "audio/mpeg" and len(data) > 1000
    assert data[:3] == b"ID3" or data[0] == 0xFF


def test_live_rewrite_returns_one_prompt(tmp_path):
    async def scenario(a):
        return (await a.status((await a.submit("openai/rewrite", rewrite("a cat on a roof"))).jobId)).text
    text = live(scenario, tmp_path)
    assert 0 < len(text) <= 1000 and "cat" in text.lower()
