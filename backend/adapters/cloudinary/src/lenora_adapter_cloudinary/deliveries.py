"""Kinds that are one signed delivery URL."""
import httpx

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import Estimate, JobError, JobRequest, JobResult, JobState
from lenora_adapter_cloudinary import costs
from lenora_adapter_cloudinary.api import CloudinaryAPI, parse_ref
from lenora_adapter_cloudinary.delivery import CONTENT_TYPES, decode_url_job, signed_url

PENDING_RETRY_AFTER = 5
RATE_LIMIT_RETRY_AFTER = 30


async def plan(api: CloudinaryAPI, job: JobRequest) -> tuple[str, Estimate]:
    """The delivery URL and estimate for an image delivery kind. Validates the input before anything is billed."""
    settings = api.settings
    secret = settings.api_secret.get_secret_value()
    ref = parse_ref(job.inputs[0], "image")
    if job.kind == "image.removeBackground":
        transformation, estimate = "e_background_removal", costs.credits(costs.REMOVE_BACKGROUND)
    else:
        raise ProblemError("unsupported_kind", f"{job.kind} is not a delivery kind.")
    return signed_url(settings.cloud_name, "image", transformation, f"{ref.public_id}.png", secret), estimate


async def status(http: httpx.AsyncClient, delivery_root: str, job_id: str) -> JobState:
    url = decode_url_job(job_id)
    if url is None or not url.startswith(delivery_root):
        raise ProblemError("not_found", "Unknown job.")
    try:
        response = await http.get(url, headers={"Range": "bytes=0-0"})
    except httpx.TransportError as error:
        raise ProblemError("provider_unavailable", f"Cloudinary is unreachable ({type(error).__name__}).") from None
    if response.status_code == 423:
        return JobState(jobId=job_id, status="running", retryAfter=PENDING_RETRY_AFTER)
    if response.status_code == 420:
        return JobState(jobId=job_id, status="running", retryAfter=RATE_LIMIT_RETRY_AFTER)
    if response.status_code in (200, 206):
        extension = url.rsplit(".", 1)[-1]
        return JobState(jobId=job_id, status="succeeded", results=[
            JobResult(url=url, contentType=CONTENT_TYPES[extension], fileExtension=extension)])
    message = response.headers.get("X-Cld-Error") or f"Cloudinary returned HTTP {response.status_code}."
    return JobState(jobId=job_id, status="failed",
                    error=JobError(code="provider_error", message=message, retryable=False))
