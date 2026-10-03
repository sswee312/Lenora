"""Image Generation add-on: text-to-image and image-to-image tasks."""
import uuid

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import ImageGenerateParams, JobError, JobResult, JobState
from lenora_adapter_cloudinary.api import CloudinaryAPI, problem
from lenora_adapter_cloudinary.delivery import CONTENT_TYPES

RUNNING_RETRY_AFTER = 5


class TaskFailed(Exception):
    pass


async def start_task(api: CloudinaryAPI, params: ImageGenerateParams, reference_asset_ids: list[str]):
    """Submit one async generation task. Returns the response so the caller can learn add-on refusals."""
    body: dict = {
        "prompt": params.prompt,
        "image_size": {"aspect_ratio": params.aspectRatio},
        "async": True,
        "target": {"target_type": "managed_asset", "public_id": f"lenora/{uuid.uuid4()}"},
    }
    if params.seed is not None:
        body["seed"] = params.seed
    endpoint = "text_to_image"
    if reference_asset_ids:
        endpoint = "image_to_image"
        body["reference_images"] = [{"source_type": "managed_asset", "asset_id": a} for a in reference_asset_ids]
    return await api.request("POST", f"/v2/generate/{api.settings.cloud_name}/{endpoint}", json=body)


def task_id(response) -> str:
    if response.status_code not in (200, 201, 202):
        raise problem(response)
    body = response.json()
    found = (body.get("data") or {}).get("task_id") or body.get("task_id")
    if not isinstance(found, str) or not found:
        raise ProblemError("provider_error", "Cloudinary accepted the task but returned no task_id.", retryable=False)
    return found


async def poll_task(api: CloudinaryAPI, task: str):
    return await api.request("GET", f"/v2/generate/{api.settings.cloud_name}/tasks/{task}")


def task_outcome(response) -> tuple[str, list[dict]]:
    """('running' | 'succeeded', assets) for a task response; raises TaskFailed or a problem."""
    if response.status_code != 200:
        raise problem(response)
    body = response.json()
    data = body.get("data") or {}
    status = data.get("status") or body.get("status")
    if status == "failed":
        error = data.get("error") or body.get("error") or {}
        raise TaskFailed((error.get("message") if isinstance(error, dict) else None) or "Image generation failed.")
    if status != "completed":
        return "running", []
    assets = (data.get("result") or {}).get("assets") or data.get("assets") or []
    if not assets:
        raise TaskFailed("Image generation completed without an image.")
    return "succeeded", assets


def results(assets: list[dict]) -> list[JobResult]:
    out = []
    for asset in assets:
        storage = asset.get("storage") or {}
        if not isinstance(storage.get("secure_url"), str):
            raise TaskFailed("Image generation returned an asset without a URL.")
        extension = (asset.get("format") or "png").lower().replace("jpeg", "jpg")
        out.append(JobResult(url=storage["secure_url"], contentType=CONTENT_TYPES.get(extension, "image/png"),
                             fileExtension=extension))
    return out


def running(job_id: str) -> JobState:
    return JobState(jobId=job_id, status="running", retryAfter=RUNNING_RETRY_AFTER)


def failed(job_id: str, message: str) -> JobState:
    return JobState(jobId=job_id, status="failed", error=JobError(code="provider_error", message=message, retryable=False))
