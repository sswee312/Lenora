import asyncio
import json

import httpx
import pytest

from cld import GEN, I2V, IMAGE_REF, admin, gen_task, i2v_job, job, run, settings
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput

ON = {"image_generation": "on", "image_to_video": "on"}


def ref(role):
    return AssetInput(assetRef=IMAGE_REF, role=role)


def chain_request():
    return job("video.generate", "cloudinary/image-to-video", {"prompt": "a paper boat", "duration": 4, "aspectRatio": "9:16"}, [])


@pytest.mark.parametrize("modes, missing", [
    ({"image_generation": "off", "image_to_video": "on"}, "Image Generation"),
    ({"image_generation": "on", "image_to_video": "off"}, "Image to Video"),
])
def test_chain_needs_both_addons(modes, missing, tmp_path):
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.submit("cloudinary/image-to-video", chain_request()), settings(tmp_path, **modes))
    assert info.value.code == "provider_unavailable" and missing in info.value.detail


def test_prompt_only_mode_is_advertised_only_with_both_addons(tmp_path):
    def caps(**modes):
        models = run(lambda a: asyncio.sleep(0, a.models()), settings(tmp_path, **modes))
        return next(m for m in models if m.id == "cloudinary/image-to-video").ui["uiCapabilities"]["requiresFirstFrame"]
    assert caps(image_generation="on", image_to_video="on") is False
    assert caps(image_generation="off", image_to_video="on") is True


def test_chain_hands_off_once_and_survives_a_restart(tmp_path):
    s = settings(tmp_path, **ON)
    video_posts = []
    image_sent = []

    def mock(r):
        r.post(f"{GEN}/text_to_image").mock(side_effect=lambda req: (
            image_sent.append(json.loads(req.content)) or httpx.Response(202, json={"data": {"task_id": "t1"}})))
        r.get(f"{GEN}/tasks/t1").respond(200, json=gen_task("completed", asset_id="frame-asset"))
        async def post_video(req):
            for _ in range(5):  # yield so a concurrent poll reaches the hand-off while this one is inside it
                await asyncio.sleep(0)
            video_posts.append(json.loads(req.content))
            return httpx.Response(201, json={"data": {"job_id": "v1"}})
        r.post(I2V).mock(side_effect=post_video)
        r.get(f"{I2V}/v1").respond(200, json=i2v_job("completed"))

    async def submit(a):
        return await a.submit("cloudinary/image-to-video", chain_request())
    submitted = run(submit, s, mock)
    assert submitted.jobId.startswith("chain:") and submitted.estimate.amount == pytest.approx(5.0)
    assert image_sent[0]["image_size"] == {"aspect_ratio": "9:16"}

    async def poll_twice_concurrently(a):
        return await asyncio.gather(a.status(submitted.jobId), a.status(submitted.jobId))
    first = run(poll_twice_concurrently, s, mock)
    assert {x.status for x in first} <= {"running", "succeeded"}
    assert len(video_posts) == 1 and video_posts[0]["image_asset_id"] == "frame-asset"

    final = run(lambda a: a.status(submitted.jobId), s, mock)
    assert final.status == "succeeded" and len(video_posts) == 1


@pytest.mark.parametrize("stage", ["image", "video"])
def test_chain_failure_at_each_stage(stage, tmp_path):
    s = settings(tmp_path, **ON)

    def mock(r):
        r.post(f"{GEN}/text_to_image").respond(202, json={"data": {"task_id": "t1"}})
        r.get(f"{GEN}/tasks/t1").respond(200, json=gen_task("failed" if stage == "image" else "completed"))
        r.post(I2V).respond(201, json={"data": {"job_id": "v1"}})
        r.get(f"{I2V}/v1").respond(200, json=i2v_job("failed"))

    async def scenario(a):
        job_id = (await a.submit("cloudinary/image-to-video", chain_request())).jobId
        await a.status(job_id)
        return await a.status(job_id)
    state = run(scenario, s, mock)
    assert state.status == "failed"
    assert state.error.message == ("First frame: Prompt rejected by moderation." if stage == "image" else "Unsafe content.")


def test_chain_rejects_other_inputs_without_a_start_frame(tmp_path):
    request = job("video.generate", "cloudinary/image-to-video", {"prompt": "x", "duration": 4}, [ref("reference")])
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.submit(request.model, request), settings(tmp_path, **ON))
    assert info.value.code == "invalid_request"


def test_unknown_chain_is_not_found(tmp_path):
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.status("chain:6f1c2b9e-0000-4000-8000-000000000000"), settings(tmp_path, **ON))
    assert info.value.code == "not_found"
