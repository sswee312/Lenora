"""Reframe for videos above the on-the-fly cap: `explicit` with `eager_async`, then poll the asset's derived list."""
import json
import re

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import JobError, JobResult, JobState
from lenora_adapter_cloudinary.api import PUBLIC_ID, AssetNotFound, AssetRef, CloudinaryAPI, problem
from lenora_adapter_cloudinary.delivery import sign_job, sign_upload, signed_url, verify_job

# Admin API calls are rate limited (500/hour on Free); poll slowly.
EAGER_RETRY_AFTER = 30
EAGER_DEADLINE_SECONDS = 30 * 60
TRANSFORMATION = re.compile(r"^ar_(9:16|1:1|4:5|16:9),c_fill,g_auto$")


def encode(public_id: str, transformation: str, started: int, secret: str) -> str:
    return sign_job("eager", json.dumps({"p": public_id, "t": transformation, "s": started}, separators=(",", ":")), secret)


def decode(job_id: str, secret: str) -> tuple[str, str, int] | None:
    raw = verify_job("eager", job_id, secret)
    try:
        data = json.loads(raw or "")
        public_id, transformation, started = data["p"], data["t"], data["s"]
    except (ValueError, KeyError, TypeError):
        return None
    if not (isinstance(public_id, str) and PUBLIC_ID.fullmatch(public_id)
            and isinstance(transformation, str) and TRANSFORMATION.match(transformation)
            and type(started) is int):
        return None
    return public_id, transformation, started


async def start(api: CloudinaryAPI, ref: AssetRef, transformation: str, timestamp: int) -> str:
    params = {"public_id": ref.public_id, "type": "upload", "eager": transformation,
              "eager_async": "true", "timestamp": str(timestamp)}
    form = {**params, "api_key": api.settings.api_key,
            "signature": sign_upload(params, api.settings.api_secret.get_secret_value())}
    response = await api.request("POST", f"/v1_1/{api.settings.cloud_name}/video/explicit", data=form)
    if response.status_code != 200:
        raise problem(response)
    return encode(ref.public_id, transformation, timestamp, api.settings.api_secret.get_secret_value())


async def status(api: CloudinaryAPI, job_id: str, now: float) -> JobState:
    secret = api.settings.api_secret.get_secret_value()
    decoded = decode(job_id, secret)
    if decoded is None:
        raise ProblemError("not_found", "Unknown job.")
    public_id, transformation, started = decoded
    try:
        asset = await api.asset(AssetRef("video", public_id))
    except AssetNotFound:
        return JobState(jobId=job_id, status="failed", error=JobError(
            code="provider_error", message="The video no longer exists.", retryable=False))
    if not any(t == transformation for t, _ in asset.derived):
        if now - started > EAGER_DEADLINE_SECONDS:
            error = JobError(code="provider_error", retryable=True,
                             message="Cloudinary did not finish the reframe in time. Submit it again.")
            return JobState(jobId=job_id, status="failed", error=error)
        return JobState(jobId=job_id, status="running", retryAfter=EAGER_RETRY_AFTER)
    url = signed_url(api.settings.cloud_name, "video", transformation, f"{public_id}.mp4", secret)
    return JobState(jobId=job_id, status="succeeded", results=[JobResult(url=url, contentType="video/mp4", fileExtension="mp4")])
