from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, RootModel, model_validator

Kind = Literal[
    "image.removeBackground", "image.generate", "image.edit", "image.upscale",
    "image.analyze", "image.enhance", "image.crop",
    "video.generate", "video.reframe", "video.publish", "video.edit", "video.lipSync", "video.upscale",
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
    maxPixels: int | None = Field(default=None, gt=0)


class ModelInfo(BaseModel):
    id: str = Field(pattern=r"^[a-z0-9_-]+/.+$")
    kind: Kind
    displayName: str
    inputs: InputLimits
    cancellable: bool
    estimate: Estimate | None = None
    ui: dict[str, Any] | None = None
    operations: list[str] | None = None
    deletable: bool | None = None


class AdapterHealth(BaseModel):
    id: str
    enabled: bool
    reason: str | None = None
    details: dict[str, Any] | None = None


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


InputRole = Literal["startFrame", "endFrame", "reference"]


class AssetInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    assetRef: str = Field(min_length=1)
    role: InputRole | None = None


class UrlInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    url: HttpUrl
    role: InputRole | None = None


class JobRequest(BaseModel):
    kind: str = Field(min_length=1, max_length=64)
    model: str
    inputs: list[AssetInput | UrlInput] = Field(default_factory=list, max_length=8)
    params: dict[str, Any] = Field(default_factory=dict)


class SubmittedJob(BaseModel):
    jobId: str
    status: JobStatus
    estimate: Estimate | None = None


ResultRole = Literal["stream", "download", "poster", "vertical", "teaser"]


class JobResult(BaseModel):
    url: HttpUrl
    contentType: str
    fileExtension: str = Field(pattern=r"^[a-z0-9]+$")
    role: ResultRole | None = None


class JobError(BaseModel):
    code: str
    message: str
    retryable: bool


class FailedOutput(BaseModel):
    role: ResultRole
    code: str
    message: str


class JobState(BaseModel):
    jobId: str
    status: JobStatus
    results: list[JobResult] | None = None
    error: JobError | None = None
    failedOutputs: list[FailedOutput] | None = None
    analysis: dict[str, Any] | None = None
    retryAfter: int | None = Field(default=None, exclude=True)

    def model_dump(self, **kwargs):
        data = super().model_dump(**kwargs)
        if data.get("analysis") is None:
            data.pop("analysis", None)
        return data


class Problem(BaseModel):
    type: str
    title: str
    status: int
    detail: str | None = None
    code: str
    retryable: bool


class StrictParams(BaseModel):
    model_config = ConfigDict(extra="forbid")


# Text that ends up inside a Cloudinary transformation URL; no URL or transformation syntax allowed.
UrlPrompt = Annotated[str, Field(pattern=r"^[A-Za-z0-9 .'-]{1,100}$")]
ImageAspect = Literal["1:1", "16:9", "9:16", "4:3", "3:4"]


class RemoveBackgroundParams(StrictParams):
    pass


class ImageUpscaleParams(StrictParams):
    pass


class TagDefinition(StrictParams):
    name: str = Field(min_length=1, max_length=100)
    description: str = Field(min_length=1, max_length=500)


class ImageAnalyzeParams(StrictParams):
    """Empty for add-ons that need only the image. AI Vision fills one of the three fields."""

    prompt: str | None = Field(default=None, min_length=1, max_length=1000)
    tags: list[TagDefinition] | None = Field(default=None, min_length=1, max_length=10)
    questions: list[Annotated[str, Field(min_length=1, max_length=300)]] | None = Field(default=None, min_length=1, max_length=10)


class ImageEnhanceParams(StrictParams):
    pass


class ImageCropParams(StrictParams):
    aspectRatio: ImageAspect = "1:1"


class ImageGenerateParams(StrictParams):
    prompt: str = Field(min_length=1, max_length=1000)
    aspectRatio: ImageAspect = "1:1"
    count: int = Field(default=1, ge=1, le=4)
    seed: int | None = Field(default=None, ge=0, le=2**31 - 1)


class FillOp(StrictParams):
    op: Literal["fill"]
    aspectRatio: ImageAspect


class ReplaceOp(StrictParams):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    op: Literal["replace"]
    from_: UrlPrompt = Field(alias="from")
    to: UrlPrompt


class RemoveOp(StrictParams):
    op: Literal["remove"]
    prompt: UrlPrompt


class RecolorOp(StrictParams):
    op: Literal["recolor"]
    prompt: UrlPrompt
    color: str = Field(pattern=r"^#[0-9A-Fa-f]{6}$")


class BackgroundReplaceOp(StrictParams):
    op: Literal["backgroundReplace"]
    prompt: UrlPrompt | None = None


class RestoreOp(StrictParams):
    op: Literal["restore"]


EditOp = Annotated[FillOp | ReplaceOp | RemoveOp | RecolorOp | BackgroundReplaceOp | RestoreOp, Field(discriminator="op")]
EDIT_OPS = ("fill", "replace", "remove", "recolor", "backgroundReplace", "restore")


class ImageEditParams(RootModel[EditOp]):
    pass


class VideoGenerateParams(StrictParams):
    prompt: str = Field(min_length=1, max_length=1000)
    duration: Literal[4, 6, 8]
    resolution: Literal["720p", "1080p"] = "720p"
    aspectRatio: Literal["16:9", "9:16"] = "16:9"
    generateAudio: bool = False

    @model_validator(mode="after")
    def _full_hd_needs_eight_seconds(self):
        if self.resolution == "1080p" and self.duration != 8:
            raise ValueError("1080p requires duration 8")
        return self


class VideoReframeParams(StrictParams):
    aspectRatio: Literal["9:16", "1:1", "4:5", "16:9"]


PublishAspect = Literal["9:16", "1:1", "4:5"]


class PublishOutputs(StrictParams):
    vertical: PublishAspect | None = None
    teaserSeconds: int | None = Field(default=None, ge=5, le=30)


class VideoPublishParams(StrictParams):
    outputs: PublishOutputs = Field(default_factory=PublishOutputs)


# Kinds the core can validate. A kind is accepted only once its params schema lands here.
PARAMS: dict[str, type[BaseModel]] = {
    "image.removeBackground": RemoveBackgroundParams,
    "image.generate": ImageGenerateParams,
    "image.edit": ImageEditParams,
    "image.upscale": ImageUpscaleParams,
    "image.analyze": ImageAnalyzeParams,
    "image.enhance": ImageEnhanceParams,
    "image.crop": ImageCropParams,
    "video.generate": VideoGenerateParams,
    "video.reframe": VideoReframeParams,
    "video.publish": VideoPublishParams,
}
# Per kind: the most inputs allowed for each role; None is the role of an unlabelled input.
INPUT_ROLES: dict[str, dict[str | None, int]] = {
    "image.removeBackground": {None: 1},
    "image.generate": {"reference": 4},
    "image.edit": {None: 1},
    "image.upscale": {None: 1},
    "image.analyze": {None: 1},
    "image.enhance": {None: 1},
    "image.crop": {None: 1},
    "video.generate": {"startFrame": 1, "endFrame": 1, "reference": 2},
    "video.reframe": {None: 1},
    "video.publish": {None: 1},
}
REQUIRED_INPUTS: dict[str, int] = {
    "image.removeBackground": 1, "image.edit": 1, "image.upscale": 1, "video.reframe": 1, "video.publish": 1,
    "image.analyze": 1, "image.enhance": 1, "image.crop": 1,
}


def input_problem(kind: str, inputs: list[AssetInput | UrlInput]) -> str | None:
    """Why `inputs` does not fit `kind`, or None when they do."""
    allowed = INPUT_ROLES[kind]
    counts: dict[str | None, int] = {}
    for item in inputs:
        counts[item.role] = counts.get(item.role, 0) + 1
    for role, count in counts.items():
        if count > allowed.get(role, 0):
            label = role or "unlabelled"
            return f"{kind} takes at most {allowed.get(role, 0)} {label} input(s); got {count}."
    if len(inputs) < REQUIRED_INPUTS.get(kind, 0):
        return f"{kind} needs {REQUIRED_INPUTS[kind]} input(s); got {len(inputs)}."
    if counts.get("endFrame") and not counts.get("startFrame"):
        return "An endFrame input needs a startFrame input."
    return None
