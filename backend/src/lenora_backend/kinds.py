from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, HttpUrl

Kind = Literal[
    "image.removeBackground", "image.generate", "image.edit", "image.upscale",
    "video.generate", "video.reframe", "video.edit", "video.lipSync", "video.upscale",
    "audio.speech", "audio.music", "audio.sfx", "text.rewritePrompt",
]
JobStatus = Literal["queued", "running", "succeeded", "failed", "cancelled"]
TERMINAL: frozenset[str] = frozenset({"succeeded", "failed", "cancelled"})


class Estimate(BaseModel):
    amount: float = Field(ge=0)
    unit: str


class InputLimits(BaseModel):
    types: list[str]
    maxBytes: int = Field(gt=0)


class ModelInfo(BaseModel):
    id: str = Field(pattern=r"^[a-z0-9_-]+/.+$")
    kind: Kind
    displayName: str
    inputs: InputLimits
    cancellable: bool
    estimate: Estimate | None = None
    ui: dict[str, Any] | None = None


class AdapterHealth(BaseModel):
    id: str
    enabled: bool
    reason: str | None = None


class Health(BaseModel):
    status: Literal["ok"] = "ok"
    protocolVersion: Literal["1"] = "1"
    backendVersion: str | None = None
    adapters: list[AdapterHealth] | None = None


class AdapterVersion(BaseModel):
    id: str
    version: str


class Capabilities(BaseModel):
    protocolVersion: Literal["1"] = "1"
    adapters: list[AdapterVersion]
    models: list[ModelInfo]


class UploadRequest(BaseModel):
    model: str
    contentType: str
    byteCount: int = Field(gt=0)
    filename: str = Field(min_length=1, max_length=255)


class Ticket(BaseModel):
    method: Literal["POST", "PUT"]
    url: HttpUrl
    headers: dict[str, str]
    fields: dict[str, str]
    fileField: str | None = None
    expiresAt: datetime


class UploadTicket(BaseModel):
    assetRef: str
    ticket: Ticket


class AssetInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    assetRef: str = Field(min_length=1)


class UrlInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    url: HttpUrl


class JobRequest(BaseModel):
    kind: Kind
    model: str
    inputs: list[AssetInput | UrlInput] = Field(min_length=1)
    params: dict[str, Any] = Field(default_factory=dict)


class SubmittedJob(BaseModel):
    jobId: str
    status: JobStatus
    estimate: Estimate | None = None


class JobResult(BaseModel):
    url: HttpUrl
    contentType: str
    fileExtension: str = Field(pattern=r"^[a-z0-9]+$")


class JobError(BaseModel):
    code: str
    message: str
    retryable: bool


class JobState(BaseModel):
    jobId: str
    status: JobStatus
    results: list[JobResult] | None = None
    error: JobError | None = None
    retryAfter: int | None = Field(default=None, exclude=True)


class Problem(BaseModel):
    type: str
    title: str
    status: int
    detail: str | None = None
    code: str
    retryable: bool


class RemoveBackgroundParams(BaseModel):
    model_config = ConfigDict(extra="forbid")


# Kinds the core can validate. A kind is accepted only once its params schema lands here.
PARAMS: dict[str, type[BaseModel]] = {"image.removeBackground": RemoveBackgroundParams}
INPUT_COUNT: dict[str, tuple[int, int]] = {"image.removeBackground": (1, 1)}
