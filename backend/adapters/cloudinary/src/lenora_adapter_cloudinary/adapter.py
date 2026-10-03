import time
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any, ClassVar

import httpx
from pydantic_settings import BaseSettings

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    InputLimits, JobRequest, JobState, ModelInfo, SubmittedJob, Ticket, UploadRequest, UploadTicket,
)
from lenora_backend.registry import CancelNotSupported
from lenora_adapter_cloudinary import costs, deliveries
from lenora_adapter_cloudinary.addons import IMAGE_GENERATION, IMAGE_TO_VIDEO, Addons
from lenora_adapter_cloudinary.api import CloudinaryAPI
from lenora_adapter_cloudinary.delivery import encode_url_job, sign_upload
from lenora_adapter_cloudinary.settings import CloudinarySettings
from lenora_adapter_cloudinary.store import Store

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
        self.store = Store(settings.data_dir / "cloudinary.sqlite3", now=clock())
        self.addons = Addons({IMAGE_GENERATION: settings.image_generation, IMAGE_TO_VIDEO: settings.image_to_video},
                             self.store)
        self.budget = costs.Budget(settings.daily_credit_budget, clock)

    def models(self) -> list[ModelInfo]:
        return [
            ModelInfo(id=BACKGROUND_REMOVAL, kind="image.removeBackground", displayName="Cloudinary Background Removal",
                      inputs=_image_inputs(), cancellable=False, estimate=costs.credits(costs.REMOVE_BACKGROUND)),
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
        url, estimate = await deliveries.plan(self.api, job)
        self.budget.reserve(estimate)
        return SubmittedJob(jobId=encode_url_job(url), status="queued", estimate=estimate)

    async def status(self, job_id: str) -> JobState:
        prefix, _, local = job_id.partition(":")
        if prefix == "url":
            return await deliveries.status(self.http, self.delivery_root, job_id)
        raise ProblemError("not_found", "Unknown job.")

    async def health(self, recheck: bool) -> dict[str, Any]:
        if recheck:
            self.addons.recheck()
        return {"addons": self.addons.details(), "budget": self.budget.usage()}
