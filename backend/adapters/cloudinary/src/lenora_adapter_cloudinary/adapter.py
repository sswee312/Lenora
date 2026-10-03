import time
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any, ClassVar

import httpx
from pydantic_settings import BaseSettings

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    EDIT_OPS, InputLimits, JobRequest, JobState, ModelInfo, SubmittedJob, Ticket, UploadRequest, UploadTicket,
)
from lenora_backend.registry import CancelNotSupported
from lenora_adapter_cloudinary import costs, deliveries
from lenora_adapter_cloudinary.addons import IMAGE_GENERATION, IMAGE_TO_VIDEO, Addons
from lenora_adapter_cloudinary.api import CloudinaryAPI
from lenora_adapter_cloudinary.delivery import encode_url_job, sign_upload
from lenora_adapter_cloudinary.settings import CloudinarySettings
from lenora_adapter_cloudinary.store import Store

BACKGROUND_REMOVAL = "cloudinary/background-removal"
GENERATIVE_EDIT = "cloudinary/generative-edit"
UPSCALE = "cloudinary/upscale"
REFRAME = "cloudinary/reframe"
IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/heic", "image/tiff"]
VIDEO_TYPES = ["video/mp4", "video/quicktime", "video/webm"]
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
            ModelInfo(id=GENERATIVE_EDIT, kind="image.edit", displayName="Cloudinary Generative Edit",
                      inputs=_image_inputs(), cancellable=False, operations=list(EDIT_OPS)),
            ModelInfo(id=UPSCALE, kind="image.upscale", displayName="Cloudinary Upscale",
                      inputs=_image_inputs(maxPixels=deliveries.UPSCALE_MAX_PIXELS), cancellable=False,
                      estimate=costs.credits(costs.UPSCALE_LARGE), ui={
                          "providerName": "Cloudinary", "allowedEndpoints": [], "responseShape": "upscaledImage",
                          "uiCapabilities": {"speed": "Fast", "p75DurationSeconds": 15, "maximumUpscaleFactor": 4,
                                             "supportedTypes": ["image"]}}),
            ModelInfo(id=REFRAME, kind="video.reframe", displayName="Cloudinary Smart Reframe",
                      inputs=InputLimits(types=VIDEO_TYPES, maxBytes=self.settings.on_the_fly_video_max_bytes),
                      cancellable=False),
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
        if job.kind == "video.reframe":
            return await self._submit_reframe(job)
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

    async def _submit_reframe(self, job: JobRequest) -> SubmittedJob:
        ref, asset, transformation, estimate = await deliveries.plan_reframe(self.api, job)
        cap = self.settings.on_the_fly_video_max_bytes
        if asset.bytes > cap:
            raise ProblemError("input_too_large", f"Reframe accepts videos up to {cap} bytes; this one is {asset.bytes}.")
        self.budget.reserve(estimate)
        url = deliveries.reframe_url(self.api, ref, transformation)
        return SubmittedJob(jobId=encode_url_job(url), status="queued", estimate=estimate)
