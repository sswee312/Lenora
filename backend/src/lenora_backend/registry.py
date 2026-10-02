import logging
from dataclasses import dataclass
from importlib.metadata import entry_points
from typing import ClassVar, Protocol

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
    names = sorted({f"LENORA_{adapter_id.upper()}_{str(e['loc'][0]).upper()}" for e in error.errors() if e["loc"]})
    return "missing or invalid: " + ", ".join(names)


class Registry:
    def __init__(self, adapters: dict[str, Adapter], statuses: list[AdapterStatus]):
        self.adapters = adapters
        self.statuses = statuses
        self._models = {m.id: (a, m) for a in adapters.values() for m in a.models()}

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

    def models(self) -> list[ModelInfo]:
        return [m for _, m in self._models.values()]

    def model(self, model_id: str) -> tuple[Adapter, ModelInfo]:
        try:
            return self._models[model_id]
        except KeyError:
            raise ProblemError("unknown_model", f"No enabled adapter provides model '{model_id}'.") from None

    def job_adapter(self, job_id: str) -> tuple[Adapter, str]:
        adapter_id, sep, local = job_id.partition(":")
        if not sep or not local or adapter_id not in self.adapters:
            raise ProblemError("not_found", "Unknown job.")
        return self.adapters[adapter_id], local
