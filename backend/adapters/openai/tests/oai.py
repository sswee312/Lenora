"""Shared builders for the OpenAI adapter tests."""
import asyncio
import tempfile
from collections.abc import Callable
from pathlib import Path

import httpx
import respx

from lenora_backend.kinds import JobRequest, JobState
from lenora_adapter_openai import OpenAIAdapter, OpenAISettings

KEY = "sk-test-0123456789abcdef"
BASE = "https://api.openai.com/v1"
SPEECH = f"{BASE}/audio/speech"
RESPONSES = f"{BASE}/responses"
MODEL = f"{BASE}/models/gpt-4o-mini-tts"
DAY = 1_790_000_000.0
AUDIO = b"ID3fake-mp3"


def settings(data_dir: Path | None = None, **overrides) -> OpenAISettings:
    """Test settings; pass pytest's tmp_path. Without one, a fresh temporary directory is used (conformance)."""
    # ponytail: conformance temp dirs are never removed; move to a session fixture if the clutter matters.
    return OpenAISettings(api_key=KEY, data_dir=data_dir or Path(tempfile.mkdtemp()), **overrides)


def run(scenario, settings_: OpenAISettings | None = None, mock=None, clock=None):
    """Run `scenario(adapter)` against respx mocks, then stop the adapter; returns the scenario's result."""
    async def go():
        with respx.mock(assert_all_called=False) as router:
            if mock:
                mock(router)
            async with httpx.AsyncClient() as http:
                kwargs = {"clock": clock} if clock else {}
                adapter = OpenAIAdapter(settings_ or settings(), http, **kwargs)
                try:
                    return await scenario(adapter)
                finally:
                    await adapter.stop()
    return asyncio.run(go())


def speech(prompt: str = "Welcome back.", **params) -> JobRequest:
    return JobRequest(kind="audio.speech", model="openai/voice", params={"prompt": prompt, **params})


def mp3_response() -> httpx.Response:
    return httpx.Response(200, content=AUDIO, headers={"content-type": "audio/mpeg"})


def mp3(router):
    return router.post(SPEECH).respond(200, content=AUDIO, headers={"content-type": "audio/mpeg"})


def error(status: int, code: str | None = None, message: str = "Something went wrong.", type_: str | None = None,
          headers: dict | None = None) -> httpx.Response:
    return httpx.Response(status, json={"error": {"message": message, "type": type_, "code": code}}, headers=headers)


class Gate:
    """An async respx side effect that holds every request until `release()`, then answers each with `respond()`."""

    def __init__(self, respond: Callable[[], httpx.Response] = mp3_response):
        self.respond = respond
        self.waiting = 0
        self._released = asyncio.Event()
        self._arrived = asyncio.Event()

    async def __call__(self, request: httpx.Request) -> httpx.Response:
        self.waiting += 1
        self._arrived.set()
        try:
            await self._released.wait()
        finally:
            self.waiting -= 1
        return self.respond()

    async def arrivals(self, count: int) -> None:
        """Return once `count` requests are held at the gate."""
        while self.waiting < count:
            self._arrived.clear()
            await self._arrived.wait()

    def release(self) -> None:
        self._released.set()


async def finished(adapter: OpenAIAdapter, request: JobRequest | None = None) -> JobState:
    """Submit one voiceover, wait for its job to end, and return the final state."""
    job = await adapter.submit("openai/voice", request or speech())
    await adapter.speech_jobs.join()
    return await adapter.status(job.jobId)
