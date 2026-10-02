import base64
import binascii
import hashlib
import re
import time
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import ClassVar, Literal

import httpx
from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    AssetInput, Estimate, InputLimits, JobError, JobRequest, JobResult, JobState, ModelInfo,
    SubmittedJob, Ticket, UploadRequest, UploadTicket,
)
from lenora_backend.registry import CancelNotSupported

BACKGROUND_REMOVAL = "cloudinary/background-removal"
IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/heic", "image/tiff"]
FREE_PLAN_IMAGE_MAX_BYTES = 10 * 1024 * 1024
ASSET_REF = re.compile(r"^image/upload/(lenora/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$")
TICKET_LIFETIME = timedelta(hours=1)
PENDING_RETRY_AFTER = 2


class CloudinarySettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LENORA_CLOUDINARY_", extra="ignore")

    cloud_name: str = Field(min_length=1, pattern=r"^[A-Za-z0-9_-]+$")
    api_key: str = Field(min_length=1)
    api_secret: SecretStr = Field(min_length=1)
    on_the_fly_video_max_bytes: int = Field(default=41943040, gt=0)
    image_generation: Literal["auto", "on", "off"] = "auto"
    image_to_video: Literal["auto", "on", "off"] = "auto"


def sign(params: dict[str, str], secret: str) -> str:
    """Cloudinary upload signature: sha1 of sorted k=v pairs joined by & plus the API secret."""
    payload = "&".join(f"{k}={params[k]}" for k in sorted(params))
    return hashlib.sha1((payload + secret).encode()).hexdigest()


def _encode(url: str) -> str:
    return "url:" + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


def _decode(job_id: str) -> str | None:
    if not job_id.startswith("url:") or len(job_id) <= 4:
        return None
    encoded = job_id[4:]
    try:
        return base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None


class CloudinaryAdapter(CancelNotSupported):
    id: ClassVar[str] = "cloudinary"
    Settings: ClassVar[type[BaseSettings]] = CloudinarySettings

    def __init__(self, settings: CloudinarySettings, http: httpx.AsyncClient, clock: Callable[[], float] = time.time):
        self.settings = settings
        self.http = http
        self.clock = clock
        self.delivery_root = f"https://res.cloudinary.com/{settings.cloud_name}/"

    def models(self) -> list[ModelInfo]:
        return [ModelInfo(
            id=BACKGROUND_REMOVAL, kind="image.removeBackground", displayName="Cloudinary Background Removal",
            inputs=InputLimits(types=IMAGE_TYPES, maxBytes=FREE_PLAN_IMAGE_MAX_BYTES), cancellable=False,
            estimate=Estimate(amount=0.075, unit="cloudinary_credits"),
        )]

    async def create_upload(self, model: str, req: UploadRequest) -> UploadTicket:
        public_id = f"lenora/{uuid.uuid4()}"
        timestamp = str(int(self.clock()))
        signed = {"public_id": public_id, "timestamp": timestamp}
        expires = datetime.fromtimestamp(int(timestamp), UTC) + TICKET_LIFETIME
        return UploadTicket(
            assetRef=f"image/upload/{public_id}",
            ticket=Ticket(
                method="POST",
                url=f"https://api.cloudinary.com/v1_1/{self.settings.cloud_name}/image/upload",
                headers={},
                fields={**signed, "api_key": self.settings.api_key,
                        "signature": sign(signed, self.settings.api_secret.get_secret_value())},
                fileField="file",
                expiresAt=expires,
            ),
        )

    async def submit(self, model: str, job: JobRequest) -> SubmittedJob:
        source = job.inputs[0]
        match = ASSET_REF.match(source.assetRef) if isinstance(source, AssetInput) else None
        if match is None:
            raise ProblemError("invalid_request", "Input must be an assetRef from this backend's upload ticket.")
        url = f"{self.delivery_root}image/upload/e_background_removal/{match.group(1)}.png"
        return SubmittedJob(jobId=_encode(url), status="queued")

    async def status(self, job_id: str) -> JobState:
        url = _decode(job_id)
        if url is None or not url.startswith(self.delivery_root):
            raise ProblemError("not_found", "Unknown job.")
        try:
            response = await self.http.get(url, headers={"Range": "bytes=0-0"})
        except httpx.TransportError as error:
            raise ProblemError("provider_unavailable", f"Cloudinary is unreachable ({type(error).__name__}).") from None
        if response.status_code == 423:
            return JobState(jobId=job_id, status="running", retryAfter=PENDING_RETRY_AFTER)
        if response.status_code in (200, 206):
            return JobState(jobId=job_id, status="succeeded",
                            results=[JobResult(url=url, contentType="image/png", fileExtension="png")])
        message = response.headers.get("X-Cld-Error") or f"Cloudinary returned HTTP {response.status_code}."
        return JobState(jobId=job_id, status="failed",
                        error=JobError(code="provider_error", message=message, retryable=False))
