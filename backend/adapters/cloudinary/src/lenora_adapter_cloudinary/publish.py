"""video.publish: one uploaded video becomes a stream, a download, a poster and optional vertical and teaser cuts."""
import json
import logging
from dataclasses import dataclass

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import (
    Estimate, FailedOutput, JobError, JobRequest, JobResult, JobState, VideoPublishParams,
)
from lenora_adapter_cloudinary import costs
from lenora_adapter_cloudinary.api import PUBLIC_ID, AssetNotFound, AssetRef, CloudinaryAPI, parse_ref, problem
from lenora_adapter_cloudinary.costs import Budget
from lenora_adapter_cloudinary.delivery import CONTENT_TYPES, sign_job, sign_upload, signed_url, verify_job

log = logging.getLogger("lenora.cloudinary")

# One upload request carries at most 100 MB; larger files need chunked upload.
MAX_BYTES = 100 * 1024 * 1024
VERTICAL_ASPECTS = ["9:16", "1:1", "4:5"]
TEASER_SECONDS = {"min": 5, "max": 30}
EAGER_TIMEOUT_SECONDS = 15 * 60
# Admin API lookups are rate limited (500/hour on Free); poll slowly.
RETRY_AFTER = 30
VIDEO_EXTENSIONS = ("mp4", "mov", "webm")


@dataclass(frozen=True)
class Output:
    role: str
    transformation: str
    extension: str

    @property
    def eager(self) -> str:
        return f"{self.transformation}/{self.extension}"

    def is_derived(self, derived: tuple[tuple[str, str | None], ...]) -> bool:
        # Admin API: m3u8 and jpg report "<t>/<ext>", mp4 reports "<t>"; match exactly, never by prefix or count.
        return any(t == self.eager or (t == self.transformation and f == self.extension) for t, f in derived)


def outputs(vertical: str | None, teaser: int | None) -> list[Output]:
    found = [Output("stream", "sp_auto:maxres_1080p", "m3u8"), Output("poster", "so_auto", "jpg")]
    if vertical:
        found.append(Output("vertical", f"ar_{vertical},c_fill,g_auto", "mp4"))
    if teaser:
        found.append(Output("teaser", f"e_preview:duration_{teaser}", "mp4"))
    return found


@dataclass(frozen=True)
class PublishJob:
    public_id: str
    extension: str
    vertical: str | None
    teaser: int | None
    submitted_at: int


def encode(job: PublishJob, secret: str) -> str:
    raw = json.dumps({"p": job.public_id, "x": job.extension, "v": job.vertical, "t": job.teaser, "s": job.submitted_at},
                     separators=(",", ":"))
    return sign_job("publish", raw, secret)


def decode(job_id: str, secret: str) -> PublishJob | None:
    try:
        data = json.loads(verify_job("publish", job_id, secret) or "")
        job = PublishJob(data["p"], data["x"], data["v"], data["t"], data["s"])
    except (ValueError, KeyError, TypeError):
        return None
    valid = (
        isinstance(job.public_id, str) and PUBLIC_ID.fullmatch(job.public_id)
        and job.extension in VIDEO_EXTENSIONS
        and (job.vertical is None or job.vertical in VERTICAL_ASPECTS)
        and (job.teaser is None or (type(job.teaser) is int and TEASER_SECONDS["min"] <= job.teaser <= TEASER_SECONDS["max"]))
        and type(job.submitted_at) is int)
    return job if valid else None


async def max_bytes(api: CloudinaryAPI) -> int:
    """The account's video upload limit, capped at one upload request."""
    try:
        response = await api.request("GET", f"/v1_1/{api.settings.cloud_name}/usage")
        limit = int(response.json()["media_limits"]["video_max_size_bytes"]) if response.status_code == 200 else None
    except (ProblemError, ValueError, KeyError, TypeError):
        limit = None
    if limit is None or limit <= 0:
        log.warning("Cloudinary usage limits unavailable; publishing accepts up to %d bytes", MAX_BYTES)
        return MAX_BYTES
    return min(MAX_BYTES, limit)


async def _post(api: CloudinaryAPI, path: str, params: dict[str, str]):
    secret = api.settings.api_secret.get_secret_value()
    form = {**params, "api_key": api.settings.api_key, "signature": sign_upload(params, secret)}
    return await api.request("POST", f"/v1_1/{api.settings.cloud_name}/video/{path}", data=form)


async def _signed_post(api: CloudinaryAPI, path: str, params: dict[str, str]):
    response = await _post(api, path, params)
    if response.status_code != 200:
        raise problem(response)
    return response


async def submit(api: CloudinaryAPI, budget: Budget, job: JobRequest, limit: int, now: int) -> tuple[str, Estimate]:
    ref = parse_ref(job.inputs[0], "video")
    requested = VideoPublishParams.model_validate(job.params).outputs
    asset = await api.asset(ref, duration=True)
    if asset.bytes > limit:
        raise ProblemError("input_too_large", f"Publish accepts videos up to {limit} bytes; this one is {asset.bytes}.")
    if not asset.duration or asset.duration <= 0:
        raise ProblemError("invalid_request", "The video has no duration.")
    if requested.teaserSeconds is not None and requested.teaserSeconds >= asset.duration:
        raise ProblemError("invalid_request", (
            f"A {requested.teaserSeconds}-second teaser needs a longer video; this one is {asset.duration:.1f} seconds."))
    if asset.format not in VIDEO_EXTENSIONS:
        raise ProblemError("invalid_request", f"Publish accepts MP4, MOV or WebM videos; this one is {asset.format}.")
    pending = [o for o in outputs(requested.vertical, requested.teaserSeconds) if not o.is_derived(asset.derived)]
    estimate = costs.publish(asset.duration, [o.role for o in pending])
    if pending:
        budget.reserve(estimate)
        # A transport failure or timeout may still have reached Cloudinary, so only a refusal is refunded.
        response = await _post(api, "explicit", {
            "public_id": ref.public_id, "type": "upload", "eager": "|".join(o.eager for o in pending),
            "eager_async": "true", "timestamp": str(now)})
        if response.status_code != 200:
            budget.refund(estimate)
            raise problem(response)
    published = PublishJob(ref.public_id, asset.format, requested.vertical, requested.teaserSeconds, now)
    return encode(published, api.settings.api_secret.get_secret_value()), estimate


def _result(api: CloudinaryAPI, role: str, transformation: str, path: str, extension: str) -> JobResult:
    url = signed_url(api.settings.cloud_name, "video", transformation, path, api.settings.api_secret.get_secret_value())
    return JobResult(url=url, contentType=CONTENT_TYPES[extension], fileExtension=extension, role=role)


async def status(api: CloudinaryAPI, job_id: str, now: int) -> JobState:
    job = decode(job_id, api.settings.api_secret.get_secret_value())
    if job is None:
        raise ProblemError("not_found", "Unknown job.")
    try:
        asset = await api.asset(AssetRef("video", job.public_id))
    except AssetNotFound:
        return JobState(jobId=job_id, status="failed", error=JobError(
            code="provider_error", message="The published video no longer exists.", retryable=False))
    results = [_result(api, "download", "", f"{job.public_id}.{job.extension}", job.extension)]
    failed: list[FailedOutput] = []
    pending = False
    for output in outputs(job.vertical, job.teaser):
        if output.is_derived(asset.derived):
            results.append(_result(api, output.role, output.transformation, f"{job.public_id}.{output.extension}",
                                   output.extension))
        elif now - job.submitted_at > EAGER_TIMEOUT_SECONDS:
            failed.append(FailedOutput(role=output.role, code="provider_error", message="Timed out after 15 minutes."))
        else:
            pending = True
    if any(f.role == "stream" for f in failed):
        return JobState(jobId=job_id, status="failed", error=JobError(
            code="provider_error", message="The stream did not finish within 15 minutes.", retryable=False))
    if pending:
        return JobState(jobId=job_id, status="running", retryAfter=RETRY_AFTER)
    return JobState(jobId=job_id, status="succeeded", results=results, failedOutputs=failed or None)


async def destroy(api: CloudinaryAPI, ref: AssetRef, now: int) -> None:
    response = await _signed_post(api, "destroy", {"public_id": ref.public_id, "invalidate": "true", "timestamp": str(now)})
    result = response.json().get("result")
    if result == "not found":
        raise ProblemError("not_found", "The asset is already deleted.")
    if result != "ok":
        raise ProblemError("provider_error", f"Cloudinary did not delete the asset ({result}).")
