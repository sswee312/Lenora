import time
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import ClassVar

import httpx
from pydantic_settings import BaseSettings

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    Estimate, InputLimits, JobRequest, JobState, ModelInfo, SubmittedJob, Ticket, UploadRequest, UploadTicket,
)
from lenora_backend.registry import CancelNotSupported
from lenora_adapter_cloudinary import deliveries
from lenora_adapter_cloudinary.api import CloudinaryAPI
from lenora_adapter_cloudinary.delivery import encode_url_job, sign_upload
from lenora_adapter_cloudinary.settings import CloudinarySettings

BACKGROUND_REMOVAL = "cloudinary/background-removal"
IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/heic", "image/tiff"]
FREE_PLAN_IMAGE_MAX_BYTES = 10 * 1024 * 1024
TICKET_LIFETIME = timedelta(hours=1)


def _image_inputs(**extra) -> InputLimits:
    return InputLimits(types=IMAGE_TYPES, maxBytes=FREE_PLAN_IMAGE_MAX_BYTES, **extra)


class CloudinaryAdapter(CancelNotSupported):
    id: ClassVar[str] = "cloudinary"
    Settings: ClassVar[type[BaseSettings]] = CloudinarySettings

    def __init__(self, settings: CloudinarySettings, http: httpx.AsyncClient, clock: Callable[[], float] = time.time):
        self.settings = settings
        self.http = http
        self.clock = clock
        self.api = CloudinaryAPI(settings, http)
        self.delivery_root = f"https://res.cloudinary.com/{settings.cloud_name}/"

    def models(self) -> list[ModelInfo]:
        return [
            ModelInfo(id=BACKGROUND_REMOVAL, kind="image.removeBackground", displayName="Cloudinary Background Removal",
                      inputs=_image_inputs(), cancellable=False, estimate=Estimate(amount=0.075, unit="cloudinary_credits")),
        ]

    async def create_upload(self, model: str, req: UploadRequest) -> UploadTicket:
        resource_type = "video" if req.contentType.startswith("video/") else "image"
        public_id = f"lenora/{uuid.uuid4()}"
        timestamp = str(int(self.clock()))
        signed = {"public_id": public_id, "timestamp": timestamp}
        return UploadTicket(
            assetRef=f"{resource_type}/upload/{public_id}",
            ticket=Ticket(
                method="POST",
                url=f"https://api.cloudinary.com/v1_1/{self.settings.cloud_name}/{resource_type}/upload",
                headers={},
                fields={**signed, "api_key": self.settings.api_key,
                        "signature": sign_upload(signed, self.settings.api_secret.get_secret_value())},
                fileField="file",
                expiresAt=datetime.fromtimestamp(int(timestamp), UTC) + TICKET_LIFETIME,
            ),
        )

    async def submit(self, model: str, job: JobRequest) -> SubmittedJob:
        url = await deliveries.plan(self.api, job)
        return SubmittedJob(jobId=encode_url_job(url), status="queued")

    async def status(self, job_id: str) -> JobState:
        prefix, _, local = job_id.partition(":")
        if prefix == "url":
            return await deliveries.status(self.http, self.delivery_root, job_id)
        raise ProblemError("not_found", "Unknown job.")
