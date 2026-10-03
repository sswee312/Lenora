"""Shared builders for the Cloudinary adapter tests."""
import asyncio
import tempfile
from pathlib import Path

import httpx
import respx

from lenora_backend.kinds import AssetInput, JobRequest
from lenora_adapter_cloudinary import CloudinaryAdapter, CloudinarySettings

CLOUD = "demo"
SECRET = "abcd"
UUID = "6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d"
IMAGE_REF = f"image/upload/lenora/{UUID}"
VIDEO_REF = f"video/upload/lenora/{UUID}"
API = "https://api.cloudinary.com"
ADMIN_IMAGE = f"{API}/v1_1/{CLOUD}/resources/image/upload/lenora/{UUID}"
ADMIN_VIDEO = f"{API}/v1_1/{CLOUD}/resources/video/upload/lenora/{UUID}"
GEN = f"{API}/v2/generate/{CLOUD}"
I2V = f"{API}/v2/video/{CLOUD}/image_to_video/generate"
USAGE = f"{API}/v1_1/{CLOUD}/usage"
DELIVERY = f"https://res.cloudinary.com/{CLOUD}/"


def settings(data_dir: Path | None = None, **overrides) -> CloudinarySettings:
    """Test settings; pass pytest's tmp_path. Without one, a fresh temporary directory is used (conformance)."""
    return CloudinarySettings(cloud_name=CLOUD, api_key="123456789012345", api_secret=SECRET,
                              data_dir=data_dir or Path(tempfile.mkdtemp()), **overrides)


def run(scenario, settings_: CloudinarySettings | None = None, mock=None, clock=None):
    """Run `scenario(adapter)` against respx mocks; returns its result."""
    async def go():
        with respx.mock(assert_all_called=False) as router:
            router.get(USAGE).respond(200, json={"media_limits": {"video_max_size_bytes": 104857600}})
            if mock:
                mock(router)
            async with httpx.AsyncClient() as http:
                kwargs = {"clock": clock} if clock else {}
                return await scenario(CloudinaryAdapter(settings_ or settings(), http, **kwargs))
    return asyncio.run(go())


def job(kind: str, model: str, params: dict | None = None, inputs: list[AssetInput] | None = None) -> JobRequest:
    return JobRequest(kind=kind, model=model, params=params or {},
                      inputs=[AssetInput(assetRef=IMAGE_REF)] if inputs is None else inputs)


def admin(router, *, width=1000, height=1000, bytes_=1000, duration=None, asset_id="asset-1", video=False):
    """Admin lookup mock; like Cloudinary, a video reports its duration only when media_metadata=true is requested."""
    body = {"asset_id": asset_id, "width": width, "height": height, "bytes": bytes_}

    def lookup(request):
        with_metadata = video and request.url.params.get("media_metadata") == "true"
        return httpx.Response(200, json={**body, "duration": duration} if with_metadata and duration is not None else body)
    return router.get(ADMIN_VIDEO if video else ADMIN_IMAGE).mock(side_effect=lookup)


def gen_task(status: str, *, asset_id="gen-asset", url="https://res.cloudinary.com/demo/image/upload/v1/lenora/out.png"):
    data = {"status": status, "task_id": "t1"}
    if status == "completed":
        data["result"] = {"assets": [{"format": "png", "storage": {"asset_id": asset_id, "secure_url": url}}]}
    if status == "failed":
        data["error"] = {"message": "Prompt rejected by moderation."}
    return {"data": data, "request_id": "r"}


def i2v_job(status: str):
    data = {"job_id": "v1", "status": status}
    if status == "completed":
        data["url"] = "https://res.cloudinary.com/demo/video/upload/v1/image-to-video/out.mp4"
    if status == "failed":
        data["error"] = {"message": "Unsafe content."}
    return {"data": data, "request_id": "r"}
