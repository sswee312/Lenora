import asyncio
import logging
from dataclasses import dataclass, replace
from importlib.metadata import entry_points
from typing import Any, ClassVar, Protocol

import httpx
from pydantic import ValidationError
from pydantic_settings import BaseSettings

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import JobRequest, JobState, ModelInfo, SubmittedJob, UploadRequest, UploadTicket

log = logging.getLogger("lenora.registry")


class Adapter(Protocol):
    id: ClassVar[str]
    Settings: ClassVar[type[BaseSettings]]

    def __init__(self, settings: BaseSettings, http: httpx.AsyncClient) -> None: ...
    def models(self) -> list[ModelInfo]: ...
    async def create_upload(self, model: str, req: UploadRequest) -> UploadTicket: ...
    async def submit(self, model: str, job: JobRequest) -> SubmittedJob: ...
    async def status(self, job_id: str) -> JobState: ...
    async def cancel(self, job_id: str) -> JobState: ...
    # Optional: `async def health(self, recheck: bool) -> dict[str, Any] | None` adds adapter details to /v1/health.
    # Optional: `async def start(self) -> None` runs once after loading, before the first request.
    # Optional: `async def stop(self) -> None` runs once at shutdown, before the HTTP client closes; it cancels
    # the adapter's background work and must not commit results after it begins.
    # Optional: `async def delete_asset(self, model: str, asset_ref: str) -> None` for models with `deletable`.


class CancelNotSupported:
    """Mixin giving adapters the protocol's default cancel behavior."""

    async def cancel(self, job_id: str) -> JobState:
        raise ProblemError("not_cancellable", "This model's jobs cannot be cancelled.")


@dataclass(frozen=True)
class AdapterStatus:
    id: str
    enabled: bool
    reason: str | None
    version: str


def missing_settings_reason(adapter_id: str, error: ValidationError) -> str:
    names = sorted({_env_name(adapter_id, str(e["loc"][0])) for e in error.errors() if e["loc"]})
    return "missing or invalid: " + ", ".join(names)


def _env_name(adapter_id: str, field: str) -> str:
    """A field read through an alias reports that alias (already a LENORA_ name); others get the adapter prefix."""
    name = field.upper()
    return name if name.startswith("LENORA_") else f"LENORA_{adapter_id.upper()}_{name}"


class Registry:
    def __init__(self, adapters: dict[str, Adapter], statuses: list[AdapterStatus]):
        self.adapters = adapters
        self.statuses = statuses

    @classmethod
    def load(cls, http: httpx.AsyncClient) -> "Registry":
        adapters: dict[str, Adapter] = {}
        statuses: list[AdapterStatus] = []
        for ep in sorted(entry_points(group="lenora.adapters"), key=lambda e: e.name):
            adapter_cls = ep.load()
            version = ep.dist.version if ep.dist else "0"
            try:
                adapter_settings = adapter_cls.Settings()
            except ValidationError as error:
                reason = missing_settings_reason(adapter_cls.id, error)
                log.warning("adapter %s disabled: %s", adapter_cls.id, reason)
                statuses.append(AdapterStatus(adapter_cls.id, False, reason, version))
                continue
            adapters[adapter_cls.id] = adapter_cls(adapter_settings, http)
            statuses.append(AdapterStatus(adapter_cls.id, True, None, version))
        return cls(adapters, statuses)

    async def start(self, timeout: float) -> None:
        for adapter_id, adapter in list(self.adapters.items()):
            if start := getattr(adapter, "start", None):
                try:
                    await asyncio.wait_for(start(), timeout)
                except Exception as error:
                    name = type(error).__name__
                    log.warning("adapter %s failed to start: %s", adapter_id, name)
                    reason = "start timed out" if isinstance(error, TimeoutError) else f"start failed: {name}"
                    del self.adapters[adapter_id]
                    self.statuses = [replace(s, enabled=False, reason=reason) if s.id == adapter_id else s
                                     for s in self.statuses]

    async def stop(self, timeout: float) -> None:
        for adapter_id, adapter in self.adapters.items():
            if stop := getattr(adapter, "stop", None):
                try:
                    await asyncio.wait_for(stop(), timeout)
                except Exception as error:
                    log.warning("adapter %s failed to stop: %s", adapter_id, type(error).__name__)

    # Models are read on every call: an adapter's offer can change at runtime (for example, a lapsed add-on).
    def models(self) -> list[ModelInfo]:
        return [m for a in self.adapters.values() for m in a.models()]

    def model(self, model_id: str) -> tuple[Adapter, ModelInfo]:
        for adapter in self.adapters.values():
            for model in adapter.models():
                if model.id == model_id:
                    return adapter, model
        raise ProblemError("unknown_model", f"No enabled adapter provides model '{model_id}'.")

    async def health_details(self, recheck: bool) -> dict[str, dict[str, Any]]:
        details = {}
        for adapter_id, adapter in self.adapters.items():
            if (health := getattr(adapter, "health", None)) and (info := await health(recheck)) is not None:
                details[adapter_id] = info
        return details

    def job_adapter(self, job_id: str) -> tuple[Adapter, str]:
        adapter_id, sep, local = job_id.partition(":")
        if not sep or not local or adapter_id not in self.adapters:
            raise ProblemError("not_found", "Unknown job.")
        return self.adapters[adapter_id], local
