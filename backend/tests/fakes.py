from typing import ClassVar

from fastapi import FastAPI
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import SecretStr

from lenora_backend.app import create_app
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    InputLimits, JobRequest, JobResult, JobState, ModelInfo, SubmittedJob, Ticket, UploadRequest, UploadTicket,
)
from lenora_backend.registry import AdapterStatus, Registry
from lenora_backend.settings import CoreSettings

TOKEN = "t" * 43
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class FakeSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LENORA_FAKE_")


class FakeAdapter:
    id: ClassVar[str] = "fake"
    Settings: ClassVar[type[BaseSettings]] = FakeSettings

    def __init__(self, settings=None, http=None):
        self.submitted: list[JobRequest] = []
        self.states: dict[str, JobState] = {}

    def models(self) -> list[ModelInfo]:
        return [ModelInfo(
            id="fake/cutout", kind="image.removeBackground", displayName="Fake Cutout",
            inputs=InputLimits(types=["image/png"], maxBytes=1000), cancellable=False,
        )]

    async def create_upload(self, model: str, req: UploadRequest) -> UploadTicket:
        return UploadTicket(assetRef="fake/asset", ticket=Ticket(
            method="PUT", url="https://upload.example/fake", headers={}, fields={},
            fileField=None, expiresAt="2030-01-01T00:00:00Z",
        ))

    async def submit(self, model: str, job: JobRequest) -> SubmittedJob:
        self.submitted.append(job)
        local = f"job{len(self.submitted)}"
        self.states[local] = JobState(jobId=local, status="running", retryAfter=3)
        return SubmittedJob(jobId=local, status="queued")

    async def status(self, job_id: str) -> JobState:
        if job_id not in self.states:
            raise ProblemError("not_found", "Unknown job.")
        return self.states[job_id]

    async def cancel(self, job_id: str) -> JobState:
        raise ProblemError("not_cancellable", "Fake jobs cannot be cancelled.")

    def finish(self, local: str) -> None:
        self.states[local] = JobState(jobId=local, status="succeeded", results=[
            JobResult(url="https://cdn.example/out.png", contentType="image/png", fileExtension="png"),
        ])


def settings(**overrides) -> CoreSettings:
    return CoreSettings(token=SecretStr(TOKEN), **overrides)


def build_app(*adapters, statuses=None, **setting_overrides) -> FastAPI:
    adapter_map = {a.id: a for a in adapters}
    status_list = statuses or [AdapterStatus(id=a.id, enabled=True, reason=None, version="0.0.1") for a in adapters]
    return create_app(settings(**setting_overrides), load_registry=lambda http: Registry(adapter_map, status_list))
