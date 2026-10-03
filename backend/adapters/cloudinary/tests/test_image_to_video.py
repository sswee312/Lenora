import asyncio
import json

import httpx
import pytest

from cld import I2V, IMAGE_REF, admin, i2v_job, job, run, settings
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput

MODEL = "cloudinary/image-to-video"


def ref(role):
    return AssetInput(assetRef=IMAGE_REF, role=role)


def model_ids(adapter) -> set[str]:
    return {m.id for m in adapter.models()}


def test_body_with_both_frames_and_a_reference(tmp_path):
    request = job("video.generate", MODEL,
                  {"prompt": "waves", "duration": 8, "resolution": "1080p", "aspectRatio": "9:16", "generateAudio": True},
                  [ref("startFrame"), ref("endFrame"), ref("reference")])
    sent = []

    def mock(r):
        admin(r, asset_id="a1")
        r.post(I2V).mock(side_effect=lambda req: (
            sent.append(json.loads(req.content)) or httpx.Response(201, json={"data": {"job_id": "v1"}})))
    submitted = run(lambda a: a.submit(MODEL, request), settings(tmp_path), mock)
    assert submitted.jobId == "i2v:v1" and submitted.estimate.amount == pytest.approx(16.0)
    assert sent[0] == {"prompt": "waves", "image_asset_id": "a1", "duration": 8, "resolution": "1080p",
                       "aspect_ratio": "9:16", "generate_audio": True, "last_frame_image_asset_id": "a1",
                       "reference_image_asset_ids": ["a1"]}


def test_minimal_body_has_no_optional_fields(tmp_path):
    sent = []

    def mock(r):
        admin(r, asset_id="a1")
        r.post(I2V).mock(side_effect=lambda req: (
            sent.append(json.loads(req.content)) or httpx.Response(201, json={"data": {"job_id": "v1"}})))
    run(lambda a: a.submit(MODEL, job("video.generate", MODEL, {"prompt": "w", "duration": 4}, [ref("startFrame")])),
        settings(tmp_path), mock)
    assert "last_frame_image_asset_id" not in sent[0] and "reference_image_asset_ids" not in sent[0]
    assert sent[0]["generate_audio"] is False and sent[0]["resolution"] == "720p"


@pytest.mark.parametrize("status, expected", [("pending", "running"), ("completed", "succeeded"), ("failed", "failed")])
def test_status(status, expected, tmp_path):
    state = run(lambda a: a.status("i2v:v1"), settings(tmp_path), lambda r: r.get(f"{I2V}/v1").respond(200, json=i2v_job(status)))
    assert state.status == expected
    if expected == "succeeded":
        assert state.results[0].contentType == "video/mp4" and state.results[0].fileExtension == "mp4"
    if expected == "failed":
        assert state.error.message == "Unsafe content."


def test_refusal_is_learned_and_refunded(tmp_path):
    s = settings(tmp_path, daily_credit_budget=10.0)
    request = job("video.generate", MODEL, {"prompt": "w", "duration": 4}, [ref("startFrame")])

    def mock(r):
        admin(r)
        r.post(I2V).respond(403, json={"request_id": "r", "error": {"message": "not enabled"}})

    async def scenario(a):
        with pytest.raises(ProblemError) as info:
            await a.submit(MODEL, request)
        return info.value.code, model_ids(a), a.budget.usage()["used"]
    code, ids, used = run(scenario, s, mock)
    assert code == "provider_unavailable" and MODEL not in ids and used == 0
    assert MODEL not in run(lambda a: asyncio.sleep(0, model_ids(a)), s)
