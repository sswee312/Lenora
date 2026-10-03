import asyncio
import os
import time

import httpx
import pytest

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput, JobRequest, UploadRequest
from lenora_adapter_cloudinary import CloudinaryAdapter, CloudinarySettings

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(not os.environ.get("LENORA_CLOUDINARY_API_SECRET"), reason="needs Cloudinary keys"),
]
SAMPLE_IMAGE = "https://res.cloudinary.com/demo/image/upload/sample.jpg"
SAMPLE_VIDEO = "https://res.cloudinary.com/demo/video/upload/dog.mp4"


async def upload(adapter, http, model: str, content_type: str, source: str) -> str:
    ticket = await adapter.create_upload(model, UploadRequest(model=model, contentType=content_type, byteCount=1, filename="s"))
    response = await http.post(str(ticket.ticket.url), data={**ticket.ticket.fields, "file": source})
    assert response.status_code == 200, response.text
    return ticket.assetRef


async def finish(adapter, job_id: str, timeout: float = 180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = await adapter.status(job_id)
        if state.status not in ("queued", "running"):
            return state
        await asyncio.sleep(state.retryAfter or 2)
    pytest.fail(f"{job_id} did not finish in {timeout} s")


def live(scenario, **overrides):
    async def go(tmp):
        async with httpx.AsyncClient(timeout=60) as http:
            return await scenario(CloudinaryAdapter(CloudinarySettings(data_dir=tmp, **overrides), http), http)
    return go


@pytest.mark.parametrize("kind, model, params", [
    ("image.removeBackground", "cloudinary/background-removal", {}),
    ("image.edit", "cloudinary/generative-edit", {"op": "fill", "aspectRatio": "16:9"}),
    ("image.edit", "cloudinary/generative-edit", {"op": "replace", "from": "the flowers", "to": "a cat"}),
    ("image.edit", "cloudinary/generative-edit", {"op": "remove", "prompt": "the bee"}),
    ("image.edit", "cloudinary/generative-edit", {"op": "recolor", "prompt": "the flowers", "color": "#1E90FF"}),
    ("image.edit", "cloudinary/generative-edit", {"op": "backgroundReplace", "prompt": "a sunny beach"}),
    ("image.edit", "cloudinary/generative-edit", {"op": "restore"}),
    ("image.upscale", "cloudinary/upscale", {}),
])
def test_image_kinds(kind, model, params, tmp_path):
    async def scenario(adapter, http):
        ref = await upload(adapter, http, model, "image/jpeg", SAMPLE_IMAGE)
        submitted = await adapter.submit(model, JobRequest(kind=kind, model=model, params=params, inputs=[AssetInput(assetRef=ref)]))
        return await finish(adapter, submitted.jobId)
    state = asyncio.run(live(scenario)(tmp_path))
    assert state.status == "succeeded", state.error
    assert httpx.get(str(state.results[0].url)).headers["content-type"].startswith("image/")


def test_small_reframe(tmp_path):
    async def scenario(adapter, http):
        ref = await upload(adapter, http, "cloudinary/reframe", "video/mp4", SAMPLE_VIDEO)
        request = JobRequest(kind="video.reframe", model="cloudinary/reframe", params={"aspectRatio": "9:16"},
                             inputs=[AssetInput(assetRef=ref)])
        return await finish(adapter, (await adapter.submit(request.model, request)).jobId, timeout=300)
    state = asyncio.run(live(scenario)(tmp_path))
    assert state.status == "succeeded", state.error
    assert httpx.get(str(state.results[0].url), headers={"Range": "bytes=0-0"}).headers["content-type"] == "video/mp4"


def test_addons_missing_on_this_account_are_learned_and_persist(tmp_path):
    """This account lacks both add-ons: one real request each is refused and remembered across restarts."""
    async def scenario(adapter, http):
        image = JobRequest(kind="image.generate", model="cloudinary/image-generation", params={"prompt": "a lighthouse"})
        with pytest.raises(ProblemError) as image_error:
            await adapter.submit(image.model, image)
        ref = await upload(adapter, http, "cloudinary/image-to-video", "image/jpeg", SAMPLE_IMAGE)
        video = JobRequest(kind="video.generate", model="cloudinary/image-to-video",
                           params={"prompt": "waves", "duration": 4}, inputs=[AssetInput(assetRef=ref, role="startFrame")])
        with pytest.raises(ProblemError) as video_error:
            await adapter.submit(video.model, video)
        return image_error.value.code, video_error.value.code

    assert asyncio.run(live(scenario)(tmp_path)) == ("provider_unavailable", "provider_unavailable")

    async def restarted(adapter, http):
        return {m.id for m in adapter.models()}
    ids = asyncio.run(live(restarted)(tmp_path))
    assert "cloudinary/image-generation" not in ids and "cloudinary/image-to-video" not in ids


def test_publish_then_unpublish(tmp_path):
    """About 0.3 credits: every publish output for the 13-second sample, then delete."""
    async def scenario(adapter, http):
        await adapter.start()
        ref = await upload(adapter, http, "cloudinary/publish", "video/mp4", SAMPLE_VIDEO)
        try:
            request = JobRequest(kind="video.publish", model="cloudinary/publish", inputs=[AssetInput(assetRef=ref)],
                                 params={"outputs": {"vertical": "9:16", "teaserSeconds": 5}})
            state = await finish(adapter, (await adapter.submit(request.model, request)).jobId, timeout=900)
        finally:
            await adapter.delete_asset("cloudinary/publish", ref)
        with pytest.raises(ProblemError) as again:
            await adapter.delete_asset("cloudinary/publish", ref)
        return state, again.value.code
    state, second_delete = asyncio.run(live(scenario)(tmp_path))
    assert state.status == "succeeded" and state.failedOutputs is None, (state.error, state.failedOutputs)
    assert sorted(r.role for r in state.results) == ["download", "poster", "stream", "teaser", "vertical"]
    assert second_delete == "not_found"
