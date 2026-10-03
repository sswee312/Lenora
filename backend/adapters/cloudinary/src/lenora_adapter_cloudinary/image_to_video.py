"""Image to Video add-on (Beta)."""
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import JobResult, VideoGenerateParams
from lenora_adapter_cloudinary.api import CloudinaryAPI, problem
from lenora_adapter_cloudinary.generation import TaskFailed


async def start_job(api: CloudinaryAPI, params: VideoGenerateParams, start: str, end: str | None, references: list[str]):
    body: dict = {
        "prompt": params.prompt,
        "image_asset_id": start,
        "duration": params.duration,
        "resolution": params.resolution,
        "aspect_ratio": params.aspectRatio,
        "generate_audio": params.generateAudio,
    }
    if end:
        body["last_frame_image_asset_id"] = end
    if references:
        body["reference_image_asset_ids"] = references
    return await api.request("POST", f"/v2/video/{api.settings.cloud_name}/image_to_video/generate", json=body)


def job_id(response) -> str:
    if response.status_code not in (200, 201, 202):
        raise problem(response)
    found = (response.json().get("data") or {}).get("job_id")
    if not isinstance(found, str) or not found:
        raise ProblemError("provider_error", "Cloudinary accepted the video job but returned no job_id.", retryable=False)
    return found


async def poll_job(api: CloudinaryAPI, video_job: str):
    return await api.request("GET", f"/v2/video/{api.settings.cloud_name}/image_to_video/generate/{video_job}")


def job_outcome(response) -> tuple[str, list[JobResult]]:
    if response.status_code != 200:
        raise problem(response)
    body = response.json()
    data = body.get("data") or {}
    if data.get("status") == "failed":
        error = data.get("error") or body.get("error") or {}
        raise TaskFailed((error.get("message") if isinstance(error, dict) else None) or "Video generation failed.")
    if data.get("status") != "completed":
        return "running", []
    if not isinstance(data.get("url"), str):
        raise TaskFailed("Video generation completed without a video URL.")
    return "succeeded", [JobResult(url=data["url"], contentType="video/mp4", fileExtension="mp4")]
