"""Template adapter. Rename the package, the id and the env prefix, then fill in each method."""
from typing import ClassVar

import httpx
from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

from lenora_backend.kinds import JobRequest, JobState, ModelInfo, SubmittedJob, UploadRequest, UploadTicket
from lenora_backend.registry import CancelNotSupported


class TemplateSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LENORA_TEMPLATE_", extra="ignore")
    api_key: SecretStr = Field(min_length=1)


class TemplateAdapter(CancelNotSupported):
    id: ClassVar[str] = "template"
    Settings: ClassVar[type[BaseSettings]] = TemplateSettings

    def __init__(self, settings: TemplateSettings, http: httpx.AsyncClient):
        self.settings = settings
        self.http = http

    def models(self) -> list[ModelInfo]:
        """Return one ModelInfo per model, with id "template/<name>" and a kind from lenora_backend.kinds.PARAMS."""
        raise NotImplementedError

    async def create_upload(self, model: str, req: UploadRequest) -> UploadTicket:
        """Return a direct-upload ticket whose assetRef already names the final object."""
        raise NotImplementedError

    async def submit(self, model: str, job: JobRequest) -> SubmittedJob:
        """Start the provider job. Encode everything status() needs into jobId, or persist it durably."""
        raise NotImplementedError

    async def status(self, job_id: str) -> JobState:
        """Map the provider's state to queued|running|succeeded|failed. Raise httpx errors as-is."""
        raise NotImplementedError
