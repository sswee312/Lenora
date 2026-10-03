"""Kinds that are one signed delivery URL: remove background, generative edits, upscale, small reframes."""
import httpx

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    Estimate, ImageEditParams, JobError, JobRequest, JobResult, JobState, VideoReframeParams,
)
from lenora_adapter_cloudinary import costs
from lenora_adapter_cloudinary.api import Asset, AssetRef, CloudinaryAPI, parse_ref
from lenora_adapter_cloudinary.delivery import CONTENT_TYPES, edit_transformation, signed_url, verify_url_job

UPSCALE_MAX_PIXELS = 2048 * 2048
PENDING_RETRY_AFTER = 5
RATE_LIMIT_RETRY_AFTER = 30


def reframe_transformation(params: VideoReframeParams) -> str:
    return f"ar_{params.aspectRatio},c_fill,g_auto"


async def plan_reframe(api: CloudinaryAPI, job: JobRequest) -> tuple[AssetRef, Asset, str, Estimate]:
    ref = parse_ref(job.inputs[0], "video")
    transformation = reframe_transformation(VideoReframeParams.model_validate(job.params))
    asset = await api.asset(ref, duration=True)
    return ref, asset, transformation, costs.reframe(asset.duration or 0)


def reframe_url(api: CloudinaryAPI, ref: AssetRef, transformation: str) -> str:
    return signed_url(api.settings.cloud_name, "video", transformation, f"{ref.public_id}.mp4",
                      api.settings.api_secret.get_secret_value())


async def plan(api: CloudinaryAPI, job: JobRequest) -> tuple[str, Estimate]:
    """The delivery URL and estimate for an image delivery kind. Validates the input before anything is billed."""
    settings = api.settings
    secret = settings.api_secret.get_secret_value()
    ref = parse_ref(job.inputs[0], "image")
    if job.kind == "image.removeBackground":
        transformation, estimate = "e_background_removal", costs.credits(costs.REMOVE_BACKGROUND)
    elif job.kind == "image.edit":
        op = ImageEditParams.model_validate(job.params).root
        transformation, estimate = edit_transformation(op), costs.credits(costs.EDIT[op.op])
    elif job.kind == "image.upscale":
        asset = await api.asset(ref)
        if (asset.width or 0) <= 0 or (asset.height or 0) <= 0:
            raise ProblemError("invalid_request", "Upscale needs an image with known dimensions.")
        pixels = asset.width * asset.height
        if pixels > UPSCALE_MAX_PIXELS:
            raise ProblemError("input_too_large", f"Upscale accepts images up to {UPSCALE_MAX_PIXELS} pixels; this one has {pixels}.")
        transformation, estimate = "e_upscale", costs.upscale(pixels)
    else:
        raise ProblemError("unsupported_kind", f"{job.kind} is not a delivery kind.")
    return signed_url(settings.cloud_name, "image", transformation, f"{ref.public_id}.png", secret), estimate


async def status(http: httpx.AsyncClient, settings, job_id: str) -> JobState:
    verified = verify_url_job(job_id, settings.cloud_name, settings.api_secret.get_secret_value())
    if verified is None:
        raise ProblemError("not_found", "Unknown job.")
    url, extension = verified
    try:
        response = await http.get(url, headers={"Range": "bytes=0-0"})
    except httpx.TransportError as error:
        raise ProblemError("provider_unavailable", f"Cloudinary is unreachable ({type(error).__name__}).") from None
    if response.status_code == 423:
        return JobState(jobId=job_id, status="running", retryAfter=PENDING_RETRY_AFTER)
    if response.status_code == 420:
        return JobState(jobId=job_id, status="running", retryAfter=RATE_LIMIT_RETRY_AFTER)
    if response.status_code == 429:
        raise ProblemError("rate_limited", "Cloudinary is rate limiting delivery.",
                           headers={"Retry-After": response.headers.get("Retry-After", str(RATE_LIMIT_RETRY_AFTER))})
    if response.status_code >= 500:
        raise ProblemError("provider_unavailable", f"Cloudinary returned HTTP {response.status_code}.")
    if response.status_code in (200, 206):
        return JobState(jobId=job_id, status="succeeded", results=[
            JobResult(url=url, contentType=CONTENT_TYPES[extension], fileExtension=extension)])
    message = response.headers.get("X-Cld-Error") or f"Cloudinary returned HTTP {response.status_code}."
    return JobState(jobId=job_id, status="failed",
                    error=JobError(code="provider_error", message=message, retryable=False))
