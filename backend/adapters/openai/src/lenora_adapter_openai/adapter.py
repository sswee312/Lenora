"""OpenAI adapter. A voiceover runs as a background job (a 4096-character script takes ~84 s, longer than the core's
submit timeout). Results live in the core ResultStore under an id chosen at submit, and job IDs are signed with a
per-installation key, so a stored result resolves from its job ID alone, also after a restart."""
import asyncio
import logging
import math
import os
import secrets
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, ClassVar

import httpx
from pydantic_settings import BaseSettings

from lenora_backend.costs import Budget
from lenora_backend.errors import ProblemError
from lenora_backend.jobids import sign_job, verify_job
from lenora_backend.kinds import (
    Estimate, InputLimits, JobError, JobRequest, JobState, ModelInfo, SpeechParams, SubmittedJob, UploadRequest,
    UploadTicket,
)
from lenora_backend.results import MAX_BYTES, ResultStore
from lenora_adapter_openai.api import OpenAIAPI
from lenora_adapter_openai.settings import OpenAISettings
from lenora_adapter_openai.speech_jobs import SpeechJob, SpeechJobs

log = logging.getLogger("lenora.openai")

VOICE = "openai/voice"
UNIT = "usd"
# ~$0.015 per minute (OpenAI estimate) at the measured 871 characters a minute, rounded up.
SPEECH_USD_PER_1000_CHARS = 0.0175
VOICES = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse", "marin", "cedar"]
DEFAULT_VOICE = "alloy"
AUDIO_TYPES = {"mp3": "audio/mpeg", "wav": "audio/wav"}
NO_INPUTS = InputLimits(types=[], maxBytes=1)
PROBE_TIMEOUT_SECONDS = 5.0
KEY_FILE = "openai.key"
JOB_DOMAINS = ("speech",)
# retryable: resubmitting can work, and the app reads a non-retryable provider_unavailable as a lost capability.
UNAVAILABLE = JobError(code="provider_unavailable", retryable=True, message=(
    "This voiceover is not available: the backend restarted before it finished, or it expired. Generate it again."))


def speech_estimate(characters: int) -> Estimate:
    return Estimate(amount=round(math.ceil(characters / 1000) * SPEECH_USD_PER_1000_CHARS, 6), unit=UNIT)


def load_signing_key(path: Path) -> str:
    """The per-installation job-ID key: created once with mode 0600. Never the OpenAI API key."""
    try:
        key = path.read_text().strip()
    except FileNotFoundError:
        key = _create_key(path)
    if len(key) < 32:
        raise RuntimeError(f"{path.name} is damaged; delete it to issue a new key (outstanding job IDs stop resolving).")
    return key


def _create_key(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    key = secrets.token_urlsafe(32)
    temp = path.with_name(f".{secrets.token_hex(8)}.tmp")
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            file.write(key)
            file.flush()
            os.fsync(file.fileno())
        os.link(temp, path)  # fails when another process installed its key first
    except FileExistsError:
        return path.read_text().strip()
    finally:
        temp.unlink(missing_ok=True)
    return key


class OpenAIAdapter:
    id: ClassVar[str] = "openai"
    Settings: ClassVar[type[BaseSettings]] = OpenAISettings

    def __init__(self, settings: OpenAISettings, http: httpx.AsyncClient, clock: Callable[[], float] = time.time):
        self.settings = settings
        self.api = OpenAIAPI(settings, http)
        self.results = ResultStore(settings.data_dir / "results", clock)
        self.budget = Budget(settings.daily_budget_usd or None, clock, provider="OpenAI", unit=UNIT, label="USD")
        self.speech_jobs = SpeechJobs(clock)
        self._signing_key: str | None = None
        self._key_rejected = False
        self._speech_model_missing = False

    async def start(self) -> None:
        await self._probe()

    async def stop(self) -> None:
        await self.speech_jobs.stop()

    def models(self) -> list[ModelInfo]:
        if self._key_rejected:
            return []
        models: list[ModelInfo] = []
        if not self._speech_model_missing:
            models.append(ModelInfo(
                id=VOICE, kind="audio.speech", displayName="OpenAI Voice", inputs=NO_INPUTS, cancellable=True,
                estimate=speech_estimate(1000), ui={
                    "providerName": "OpenAI", "providerIconKey": "openai",
                    "uiCapabilities": {
                        "category": "tts", "voices": VOICES, "defaultVoice": DEFAULT_VOICE, "supportsLyrics": False,
                        "supportsInstrumental": False, "supportsStyleInstructions": True, "minPromptLength": 1,
                        "promptLabel": "Script", "inputs": ["text"]}}))
        return models

    async def create_upload(self, model: str, req: UploadRequest) -> UploadTicket:
        raise ProblemError("invalid_request", f"{model} takes no media inputs.")

    async def submit(self, model: str, job: JobRequest) -> SubmittedJob:
        if model == VOICE:
            return await self._speech(SpeechParams.model_validate(job.params))
        raise ProblemError("unknown_model", f"No OpenAI model '{model}'.")

    async def status(self, job_id: str) -> JobState:
        _, result_id = await self._verify(job_id)
        return await self._speech_state(job_id, result_id)

    async def cancel(self, job_id: str) -> JobState:
        _, result_id = await self._verify(job_id)
        await self.speech_jobs.cancel(result_id)
        return await self._speech_state(job_id, result_id)

    async def health(self, recheck: bool) -> dict[str, Any]:
        if recheck:
            await self._probe()
        reason = ("OpenAI rejected the API key." if self._key_rejected
                  else f"{self.settings.speech_model} is not available to this API key." if self._speech_model_missing
                  else None)
        return {"budget": self.budget.usage(),
                "addons": [{"id": self.settings.speech_model, "mode": "on", "available": reason is None, "reason": reason}]}

    async def _speech(self, params: SpeechParams) -> SubmittedJob:
        voice = params.voice or DEFAULT_VOICE
        if voice not in VOICES:
            raise ProblemError("invalid_request", f"Unknown voice '{voice}'. Voices: {', '.join(VOICES)}.")
        key = await self._key()
        estimate = speech_estimate(len(params.prompt))
        body = {"model": self.settings.speech_model, "input": params.prompt, "voice": voice,
                "response_format": params.format}
        if params.styleInstructions:
            body["instructions"] = params.styleInstructions
        # No await from here to launch: admission, reservation and the table insert are atomic on the loop.
        self.speech_jobs.admit()
        self.budget.reserve(estimate)
        result_id = ResultStore.new_id()
        self.speech_jobs.launch(result_id, lambda job: self._speak(job, result_id, body, params.format),
                                lambda: self.budget.refund(estimate))
        return SubmittedJob(jobId=sign_job("speech", result_id, key), status="queued", estimate=estimate)

    async def _speak(self, job: SpeechJob, result_id: str, body: dict, fmt: str) -> None:
        audio = await self.api.speech(body, MAX_BYTES)
        job.phase = "store"
        write = asyncio.ensure_future(self.results.put_bytes(audio, AUDIO_TYPES[fmt], fmt, result_id=result_id))
        try:
            await asyncio.shield(write)
        except asyncio.CancelledError:
            # The threaded write cannot be interrupted: let it finish, then remove what it installed.
            await asyncio.wait({write})
            try:
                await self.results.delete(result_id)
            except OSError as error:
                log.warning("speech job %s could not remove its cancelled result: %s", result_id, type(error).__name__)
            raise

    async def _speech_state(self, job_id: str, result_id: str) -> JobState:
        if (job := self.speech_jobs.get(result_id)) is not None:
            return JobState(jobId=job_id, status=job.status, error=job.error)
        try:
            stored = await self.results.open(result_id)
        except ProblemError:
            return JobState(jobId=job_id, status="failed", error=UNAVAILABLE)
        return JobState(jobId=job_id, status="succeeded",
                        results=[ResultStore.result(result_id, stored.content_type, stored.file_extension)])

    async def _verify(self, job_id: str) -> tuple[str, str]:
        domain = job_id.partition(":")[0]
        result_id = verify_job(domain, job_id, await self._key()) if domain in JOB_DOMAINS else None
        if result_id is None:
            raise ProblemError("not_found", "Unknown job.")
        return domain, result_id

    async def _key(self) -> str:
        if self._signing_key is None:
            self._signing_key = await asyncio.to_thread(load_signing_key, self.settings.data_dir / KEY_FILE)
        return self._signing_key

    async def _probe(self) -> None:
        """One bounded model lookup. A definite refusal hides models; anything else keeps the last answer."""
        try:
            status = await asyncio.wait_for(self.api.model_status(self.settings.speech_model), PROBE_TIMEOUT_SECONDS)
        except (TimeoutError, ProblemError):
            return
        if status in (401, 403):
            self._key_rejected = True
        elif status == 404:
            self._key_rejected, self._speech_model_missing = False, True
        elif status == 200:
            self._key_rejected = self._speech_model_missing = False
