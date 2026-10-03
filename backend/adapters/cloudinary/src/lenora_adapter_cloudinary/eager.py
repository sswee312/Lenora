"""Reframe for videos above the on-the-fly cap: `explicit` with `eager_async`, then poll the asset's derived list."""
import base64
import binascii
import json
import re

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import JobError, JobResult, JobState
from lenora_adapter_cloudinary.api import AssetRef, CloudinaryAPI, problem
from lenora_adapter_cloudinary.delivery import sign_upload, signed_url

# Admin API calls are rate limited (500/hour on Free); poll slowly.
EAGER_RETRY_AFTER = 30
EAGER_DEADLINE_SECONDS = 30 * 60
PUBLIC_ID = re.compile(r"^lenora/[A-Za-z0-9_-]+$")
TRANSFORMATION = re.compile(r"^ar_(9:16|1:1|4:5|16:9),c_fill,g_auto$")


def encode(public_id: str, transformation: str, started: int) -> str:
    raw = json.dumps({"p": public_id, "t": transformation, "s": started}, separators=(",", ":"))
    return "eager:" + base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")


def decode(job_id: str) -> tuple[str, str, int] | None:
    encoded = job_id.removeprefix("eager:")
    try:
        data = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        public_id, transformation, started = data["p"], data["t"], data["s"]
    except (binascii.Error, ValueError, KeyError, TypeError):
        return None
    if not (isinstance(public_id, str) and PUBLIC_ID.match(public_id)
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
    return encode(ref.public_id, transformation, timestamp)


async def status(api: CloudinaryAPI, job_id: str, now: float) -> JobState:
    decoded = decode(job_id)
    if decoded is None:
        raise ProblemError("not_found", "Unknown job.")
    public_id, transformation, started = decoded
    response = await api.request("GET", f"/v1_1/{api.settings.cloud_name}/resources/video/upload/{public_id}")
    if response.status_code != 200:
        raise problem(response)
    if not any(d.get("transformation") == transformation for d in response.json().get("derived") or []):
        if now - started > EAGER_DEADLINE_SECONDS:
            error = JobError(code="provider_error", retryable=True,
                             message="Cloudinary did not finish the reframe in time. Submit it again.")
            return JobState(jobId=job_id, status="failed", error=error)
        return JobState(jobId=job_id, status="running", retryAfter=EAGER_RETRY_AFTER)
    url = signed_url(api.settings.cloud_name, "video", transformation, f"{public_id}.mp4",
                     api.settings.api_secret.get_secret_value())
    return JobState(jobId=job_id, status="succeeded", results=[JobResult(url=url, contentType="video/mp4", fileExtension="mp4")])
