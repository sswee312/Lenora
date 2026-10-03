"""HTTP calls to OpenAI. Error bodies are read only for a code and a safe message; they are never logged or passed on."""
import asyncio
import re

import httpx

from lenora_backend.errors import NOT_SENT, ProblemError, RequestNotSent
from lenora_adapter_openai.settings import OpenAISettings

DEFAULT_RATE_LIMIT_RETRY = 20
MESSAGE_LIMIT = 300
# Read is the longest silence between audio chunks; the spike's first byte came after 1.5 s.
SPEECH_TIMEOUT = httpx.Timeout(connect=5.0, read=60.0, write=30.0, pool=5.0)
# 3.5× the spike's 84 s for a 4096-character script.
SPEECH_TOTAL_SECONDS = 300
_SECRET = re.compile(r"sk-[A-Za-z0-9_*-]{4,}|bearer\s+\S+", re.IGNORECASE)


class Refused(ProblemError):
    """OpenAI answered with an error status, so the request produced nothing billable."""


def unreachable(error: httpx.TransportError) -> ProblemError:
    kind = RequestNotSent if isinstance(error, NOT_SENT) else ProblemError
    return kind("provider_unavailable", f"OpenAI is unreachable ({type(error).__name__}).")


def safe_message(message: object) -> str:
    if not isinstance(message, str) or not message.strip() or _SECRET.search(message):
        return "OpenAI rejected the request."
    return f"OpenAI rejected the request: {message.strip()[:MESSAGE_LIMIT]}"


def _error(response: httpx.Response) -> dict:
    try:
        body = response.json()
    except ValueError:
        return {}
    error = body.get("error") if isinstance(body, dict) else None
    return error if isinstance(error, dict) else {}


def _retry_after(response: httpx.Response) -> int:
    try:
        return max(1, int(float(response.headers.get("retry-after", ""))))
    except ValueError:
        return DEFAULT_RATE_LIMIT_RETRY


def refusal(response: httpx.Response) -> Refused:
    status, error = response.status_code, _error(response)
    if status in (401, 403):
        return Refused("provider_unavailable", "OpenAI rejected the API key or the project's access.", retryable=False)
    if status == 429:
        if "insufficient_quota" in (error.get("code"), error.get("type")):
            return Refused("quota_exceeded", "The OpenAI account has no quota left; check billing on platform.openai.com.",
                           retryable=False)
        return Refused("rate_limited", "OpenAI is rate limiting requests.", headers={"Retry-After": str(_retry_after(response))})
    if status in (400, 422):
        return Refused("invalid_request", safe_message(error.get("message")))
    if status == 404:
        return Refused("provider_error", "The configured OpenAI model is not available.", retryable=False)
    if status >= 500:
        return Refused("provider_error", f"OpenAI failed (HTTP {status}).", retryable=True)
    return Refused("provider_error", f"OpenAI refused the request (HTTP {status}).", retryable=False)


class OpenAIAPI:
    def __init__(self, settings: OpenAISettings, http: httpx.AsyncClient):
        self.http = http
        self.base = settings.base_url.rstrip("/")
        self.headers = {"Authorization": f"Bearer {settings.api_key.get_secret_value()}"}

    async def speech(self, body: dict, max_bytes: int) -> bytes:
        try:
            async with asyncio.timeout(SPEECH_TOTAL_SECONDS):
                async with self.http.stream("POST", f"{self.base}/audio/speech", json=body, headers=self.headers,
                                            timeout=SPEECH_TIMEOUT) as response:
                    if response.status_code != 200:
                        await response.aread()
                        raise refusal(response)
                    audio = bytearray()
                    async for chunk in response.aiter_bytes():
                        audio += chunk
                        if len(audio) > max_bytes:
                            raise ProblemError("provider_error", "OpenAI returned more audio than the 25 MB result limit.",
                                               retryable=False)
        except TimeoutError:
            raise ProblemError("provider_unavailable", "OpenAI did not finish the voiceover in time.") from None
        except httpx.TransportError as error:
            raise unreachable(error) from None
        if not audio:
            raise ProblemError("provider_error", "OpenAI returned no audio.", retryable=True)
        return bytes(audio)

    async def model_status(self, model: str) -> int:
        try:
            response = await self.http.get(f"{self.base}/models/{model}", headers=self.headers)
        except httpx.TransportError as error:
            raise unreachable(error) from None
        return response.status_code

    async def respond(self, body: dict) -> object:
        try:
            response = await self.http.post(f"{self.base}/responses", json=body, headers=self.headers)
        except httpx.TransportError as error:
            raise unreachable(error) from None
        if response.status_code != 200:
            raise refusal(response)
        try:
            return response.json()
        except ValueError:
            raise ProblemError("provider_error", "OpenAI returned an unreadable response.", retryable=True) from None
