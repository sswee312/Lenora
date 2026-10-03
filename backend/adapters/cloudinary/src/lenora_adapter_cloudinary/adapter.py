import asyncio
import time
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any, ClassVar

import httpx
from pydantic_settings import BaseSettings

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    EDIT_OPS, AssetInput, Estimate, ImageGenerateParams, InputLimits, JobError, JobRequest, JobState, ModelInfo, SubmittedJob, Ticket,
    UploadRequest, UploadTicket, VideoGenerateParams,
)
from lenora_backend.registry import CancelNotSupported
from lenora_adapter_cloudinary import analysis, costs, deliveries, eager, generation, image_to_video, publish
from lenora_adapter_cloudinary.account import ANALYSIS_MODELS, DELIVERY_MODELS, AccountAddons
from lenora_adapter_cloudinary.addons import IMAGE_GENERATION, IMAGE_TO_VIDEO, Addons
from lenora_adapter_cloudinary.api import CloudinaryAPI, is_subscription_refusal, parse_ref
from lenora_adapter_cloudinary.delivery import encode_url_job, sign_upload
from lenora_adapter_cloudinary.generation import TaskFailed
from lenora_adapter_cloudinary.settings import CloudinarySettings
from lenora_adapter_cloudinary.store import Store

BACKGROUND_REMOVAL = "cloudinary/background-removal"
GENERATIVE_EDIT = "cloudinary/generative-edit"
UPSCALE = "cloudinary/upscale"
REFRAME = "cloudinary/reframe"
IMAGE_GENERATION_MODEL = "cloudinary/image-generation"
IMAGE_TO_VIDEO_MODEL = "cloudinary/image-to-video"
PUBLISH = "cloudinary/publish"
FREE_PLAN_VIDEO_MAX_BYTES = 100 * 1024 * 1024
IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/heic", "image/tiff"]
VIDEO_TYPES = ["video/mp4", "video/quicktime", "video/webm"]
FREE_PLAN_IMAGE_MAX_BYTES = 10 * 1024 * 1024
TICKET_LIFETIME = timedelta(hours=1)
IMAGE_ASPECTS = ["1:1", "16:9", "9:16", "4:3", "3:4"]


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
        self.store = Store(settings.data_dir / "cloudinary.sqlite3", now=clock())
        self.addons = Addons({IMAGE_GENERATION: settings.image_generation, IMAGE_TO_VIDEO: settings.image_to_video},
                             self.store)
        self.account = AccountAddons()
        # ponytail: one lock serializes chain hand-offs in this process; a shared store needs a row lock instead.
        self._chain_lock = asyncio.Lock()
        self.budget = costs.Budget(settings.daily_credit_budget, clock)
        self.publish_max_bytes = publish.MAX_BYTES

    async def start(self) -> None:
        await self.account.refresh(self.api)
        self.publish_max_bytes = publish.limit_from_usage(self.account.report)

    def models(self) -> list[ModelInfo]:
        models = [
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
                      inputs=InputLimits(types=VIDEO_TYPES, maxBytes=FREE_PLAN_VIDEO_MAX_BYTES),
                      cancellable=False),
            ModelInfo(id=PUBLISH, kind="video.publish", displayName="Cloudinary Publish",
                      inputs=InputLimits(types=VIDEO_TYPES, maxBytes=self.publish_max_bytes), cancellable=False,
                      deletable=True, ui={"publish": {"verticalAspects": publish.VERTICAL_ASPECTS,
                                                      "teaserSeconds": publish.TEASER_SECONDS}}),
        ]
        if self.addons.available(IMAGE_GENERATION):
            models.append(ModelInfo(
                id=IMAGE_GENERATION_MODEL, kind="image.generate", displayName="Cloudinary Image Generation",
                inputs=_image_inputs(), cancellable=False,
                estimate=costs.image_generation(self.settings.cost_image_generation, 1), ui={
                    "providerName": "Cloudinary", "allowedEndpoints": [], "responseShape": "images",
                    "uiCapabilities": {"aspectRatios": IMAGE_ASPECTS, "supportsImageReference": True, "maxImages": 4}}))
        if self.addons.available(IMAGE_TO_VIDEO):
            models.append(ModelInfo(
                id=IMAGE_TO_VIDEO_MODEL, kind="video.generate", displayName="Cloudinary Image to Video",
                inputs=_image_inputs(), cancellable=False, ui={
                    "providerName": "Cloudinary", "allowedEndpoints": [], "responseShape": "video",
                    "uiCapabilities": {
                        "supportsPrompt": True, "durations": [4, 6, 8], "resolutions": ["720p", "1080p"],
                        "aspectRatios": ["16:9", "9:16"], "supportsFirstFrame": True, "supportsLastFrame": True,
                        "maxReferenceImages": 2, "maxReferenceVideos": 0, "maxReferenceAudios": 0,
                        "framesAndReferencesExclusive": False, "referenceTagNoun": "Image",
                        "requiresSourceVideo": False, "requiresReferenceImage": False,
                        "requiresFirstFrame": not self.addons.available(IMAGE_GENERATION)}}))
        models.extend(self._account_models())
        return models

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
        if job.kind == "image.generate":
            return await self._submit_image_generation(job)
        if job.kind == "video.generate":
            if any(i.role == "startFrame" for i in job.inputs):
                return await self._submit_image_to_video(job)
            return await self._submit_chain(job)
        if job.kind == "video.reframe":
            return await self._submit_reframe(job)
        if job.kind == "video.publish":
            job_id, estimate = await publish.submit(self.api, self.budget, job, self.publish_max_bytes, int(self.clock()))
            return SubmittedJob(jobId=job_id, status="queued", estimate=estimate)
        if job.kind == "image.analyze":
            return await analysis.submit(self, job)
        if job.kind in ("image.enhance", "image.crop"):
            return analysis.submit_delivery(self, job)
        url, estimate = await deliveries.plan(self.api, job)
        self.budget.reserve(estimate)
        return SubmittedJob(jobId=encode_url_job(url), status="queued", estimate=estimate)

    async def status(self, job_id: str) -> JobState:
        prefix, _, local = job_id.partition(":")
        if prefix == "url":
            return await deliveries.status(self.http, self.settings, job_id)
        try:
            if prefix == "gen" and local:
                return await self._image_generation_status(job_id, local.split("."))
            if prefix == "i2v" and local:
                return await self._image_to_video_status(job_id, local)
            if prefix == "chain" and local:
                return await self._chain_status(job_id, local)
            if prefix == "an" and local:
                return await analysis.status(self, job_id, local)
        except ProblemError as error:
            if error.code != "provider_unavailable" or error.retryable:
                raise
            return JobState(jobId=job_id, status="failed",
                            error=JobError(code="provider_unavailable", message=error.detail, retryable=False))
        if prefix == "publish" and local:
            return await publish.status(self.api, job_id, int(self.clock()))
        if prefix == "eager" and local:
            return await eager.status(self.api, job_id, self.clock())
        raise ProblemError("not_found", "Unknown job.")

    async def delete_asset(self, model: str, asset_ref: str) -> None:
        await publish.destroy(self.api, parse_ref(AssetInput(assetRef=asset_ref), "video"), int(self.clock()))

    async def health(self, recheck: bool) -> dict[str, Any]:
        if recheck:
            self.addons.recheck()
        await self.account.refresh(self.api)
        if self.account.report is not None:
            self.publish_max_bytes = publish.limit_from_usage(self.account.report)
        return {"addons": self.addons.details() + self.account.details(), "budget": self.budget.usage()}

    def _account_models(self) -> list[ModelInfo]:
        enabled = self.account.enabled
        models = [
            ModelInfo(id=spec.id, kind="image.analyze", displayName=spec.display_name, inputs=_image_inputs(),
                      cancellable=False, estimate=analysis.ADDON_ESTIMATE,
                      ui={"providerName": "Cloudinary", "responseShape": "analysis"})
            for spec in ANALYSIS_MODELS if spec.addon in enabled
        ]
        models.extend(
            ModelInfo(id=spec.id, kind=spec.kind, displayName=spec.display_name, inputs=_image_inputs(),
                      cancellable=False, estimate=analysis.ADDON_ESTIMATE,
                      ui={"providerName": "Cloudinary", "responseShape": "image"})
            for spec in DELIVERY_MODELS if spec.addon in enabled
        )
        return models

    async def _submit_reframe(self, job: JobRequest) -> SubmittedJob:
        ref, asset, transformation, estimate = await deliveries.plan_reframe(self.api, job)
        if asset.bytes > FREE_PLAN_VIDEO_MAX_BYTES:
            raise ProblemError("input_too_large", f"Reframe accepts videos up to {FREE_PLAN_VIDEO_MAX_BYTES} bytes; this one is {asset.bytes}.")
        if asset.bytes > self.settings.on_the_fly_video_max_bytes:
            job_id = await self._charged(estimate, lambda: eager.start(self.api, ref, transformation, int(self.clock())))
            return SubmittedJob(jobId=job_id, status="queued", estimate=estimate)
        self.budget.reserve(estimate)
        url = deliveries.reframe_url(self.api, ref, transformation)
        return SubmittedJob(jobId=encode_url_job(url), status="queued", estimate=estimate)

    # Add-on calls

    def _require(self, *addons: str) -> None:
        for addon in addons:
            if not self.addons.available(addon):
                raise self.addons.refusal(addon)

    def _checked(self, addon: str, response: httpx.Response) -> httpx.Response:
        if is_subscription_refusal(response):
            raise self.addons.learn_refusal(addon, str(response.status_code), self.clock())
        return response

    async def _asset_ids(self, inputs) -> list[str]:
        return [(await self.api.asset(parse_ref(i, "image"))).asset_id for i in inputs]

    async def _charged(self, estimate: Estimate, call):
        self.budget.reserve(estimate)
        try:
            return await call()
        except BaseException:
            self.budget.refund(estimate)
            raise

    async def _start_image_task(self, params: ImageGenerateParams, references: list[str]) -> str:
        response = await generation.start_task(self.api, params, references)
        return generation.task_id(self._checked(IMAGE_GENERATION, response))

    async def _start_video_job(self, params: VideoGenerateParams, start: str, end: str | None, refs: list[str]) -> str:
        response = await image_to_video.start_job(self.api, params, start, end, refs)
        return image_to_video.job_id(self._checked(IMAGE_TO_VIDEO, response))

    def _video_estimate(self, params: VideoGenerateParams) -> Estimate:
        return costs.image_to_video(self.settings.cost_image_to_video_per_second, params.duration, params.generateAudio)

    # image.generate

    async def _submit_image_generation(self, job: JobRequest) -> SubmittedJob:
        self._require(IMAGE_GENERATION)
        params = ImageGenerateParams.model_validate(job.params)
        references = await self._asset_ids(job.inputs)
        per_image = costs.image_generation(self.settings.cost_image_generation, 1)
        estimate = costs.image_generation(self.settings.cost_image_generation, params.count)
        self.budget.reserve(estimate)
        tasks: list[str] = []
        try:
            for _ in range(params.count):
                tasks.append(await self._start_image_task(params, references))
        except BaseException:
            unsent = params.count - len(tasks)
            self.budget.refund(Estimate(amount=per_image.amount * unsent, unit=per_image.unit))
            raise
        return SubmittedJob(jobId="gen:" + ".".join(tasks), status="queued", estimate=estimate)

    async def _image_generation_status(self, job_id: str, tasks: list[str]) -> JobState:
        assets: list[dict] = []
        try:
            for task in tasks:
                state, found = generation.task_outcome(self._checked(IMAGE_GENERATION, await generation.poll_task(self.api, task)))
                if state == "running":
                    return generation.running(job_id)
                assets.extend(found)
            return JobState(jobId=job_id, status="succeeded", results=generation.results(assets))
        except TaskFailed as error:
            return generation.failed(job_id, str(error))

    # video.generate with a start frame

    async def _submit_image_to_video(self, job: JobRequest) -> SubmittedJob:
        self._require(IMAGE_TO_VIDEO)
        params = VideoGenerateParams.model_validate(job.params)
        by_role = {role: [i for i in job.inputs if i.role == role] for role in ("startFrame", "endFrame", "reference")}
        start = (await self._asset_ids(by_role["startFrame"]))[0]
        end = next(iter(await self._asset_ids(by_role["endFrame"])), None)
        references = await self._asset_ids(by_role["reference"])
        estimate = self._video_estimate(params)
        video_job = await self._charged(estimate, lambda: self._start_video_job(params, start, end, references))
        return SubmittedJob(jobId=f"i2v:{video_job}", status="queued", estimate=estimate)

    async def _image_to_video_status(self, job_id: str, video_job: str) -> JobState:
        try:
            state, results = image_to_video.job_outcome(
                self._checked(IMAGE_TO_VIDEO, await image_to_video.poll_job(self.api, video_job)))
        except TaskFailed as error:
            return generation.failed(job_id, str(error))
        if state == "running":
            return generation.running(job_id)
        return JobState(jobId=job_id, status="succeeded", results=results)

    # video.generate from a prompt alone: text-to-image, then image-to-video

    async def _submit_chain(self, job: JobRequest) -> SubmittedJob:
        self._require(IMAGE_GENERATION, IMAGE_TO_VIDEO)
        params = VideoGenerateParams.model_validate(job.params)
        if job.inputs:
            raise ProblemError("invalid_request", "Without a startFrame, video.generate takes no other inputs.")
        image = costs.image_generation(self.settings.cost_image_generation, 1)
        video = self._video_estimate(params)
        estimate = Estimate(amount=image.amount + video.amount, unit=image.unit)
        frame = ImageGenerateParams(prompt=params.prompt, aspectRatio=params.aspectRatio)
        task = await self._charged(estimate, lambda: self._start_image_task(frame, []))
        chain_id = str(uuid.uuid4())
        self.store.insert_chain(chain_id, task, params.model_dump(), self.clock())
        return SubmittedJob(jobId=f"chain:{chain_id}", status="queued", estimate=estimate)

    async def _chain_status(self, job_id: str, chain_id: str) -> JobState:
        chain = self.store.chain(chain_id)
        if chain is None:
            raise ProblemError("not_found", "Unknown job.")
        if chain.stage == "image":
            try:
                state, assets = generation.task_outcome(
                    self._checked(IMAGE_GENERATION, await generation.poll_task(self.api, chain.gen_task_id)))
            except TaskFailed as error:
                return generation.failed(job_id, f"First frame: {error}")
            if state == "running":
                return generation.running(job_id)
            async with self._chain_lock:
                chain = self.store.chain(chain_id)
                if chain.stage == "image":
                    start = (assets[0].get("storage") or {}).get("asset_id")
                    if not isinstance(start, str):
                        return generation.failed(job_id, "First frame: generated image has no asset_id.")
                    self._require(IMAGE_TO_VIDEO)
                    params = VideoGenerateParams.model_validate(chain.params)
                    self.store.advance_chain(chain_id, await self._start_video_job(params, start, None, []))
            return generation.running(job_id)
        return await self._image_to_video_status(job_id, chain.i2v_id)
