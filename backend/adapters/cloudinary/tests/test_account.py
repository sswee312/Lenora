"""Subscribed Cloudinary add-ons load from the usage report into health and models."""
import httpx
import pytest

from cld import ADMIN_IMAGE, API, IMAGE_REF, USAGE, job, run, settings
from lenora_backend.errors import ProblemError
from lenora_adapter_cloudinary.delivery import decode_url_job

ANALYZE = f"{API}/v2/analysis/{CLOUD}/analyze"
EXPLICIT = f"{API}/v1_1/{CLOUD}/image/explicit"
USAGE_BODY = {
    "plan": "Free",
    "media_limits": {"video_max_size_bytes": 104857600},
    "bandwidth": {"usage": 1, "limit": 9},
    "impressions": {"usage": 1, "limit": None},
    "image_generation": {"usage": 53, "limit": 50},
    "google_tagging": {"usage": 0, "limit": 50},
    "ai_vision": {"usage": 1, "limit": 100000},
    "imagga_tagging": {"usage": 0, "limit": 50},
    "imagga_crop": {"usage": 0, "limit": 50},
    "object_detection": {"usage": 0, "limit": 500},
    "url2png": {"usage": 0, "limit": 50},
    "viesus_correct": {"usage": 0, "limit": 50},
}


def loaded(tmp_path, body=USAGE_BODY, status_code=200):
    async def scenario(adapter):
        await adapter.health(recheck=False)
        return adapter
    return run(scenario, settings(tmp_path), lambda r: r.get(USAGE).respond(status_code, json=body))


def test_usage_report_lists_subscribed_addons_and_skips_product_counters(tmp_path):
    adapter = loaded(tmp_path)
    rows = {row["id"]: row for row in adapter.account.details()}
    assert rows["google_tagging"] == {"id": "google_tagging", "mode": "account", "available": True, "reason": "0 of 50 used"}
    assert rows["url2png"]["available"] and "image_generation" not in rows and "bandwidth" not in rows
    ids = {model.id for model in adapter.models()}
    assert "cloudinary/google-tagging" in ids and "cloudinary/captioning" in ids
    assert "cloudinary/ai-vision" in ids and "cloudinary/viesus-correct" in ids and "cloudinary/imagga-crop" in ids
    assert "cloudinary/url2png" not in ids


def test_models_stay_hidden_until_the_usage_report_loads(tmp_path):
    async def scenario(adapter):
        return adapter.models()
    ids = {model.id for model in run(scenario, settings(tmp_path))}
    assert "cloudinary/google-tagging" not in ids and "cloudinary/viesus-correct" not in ids


def test_a_failed_usage_report_keeps_health_up_and_the_previous_list(tmp_path):
    shared = settings(tmp_path)

    async def scenario(adapter):
        await adapter.health(recheck=False)
        first = [row["id"] for row in adapter.account.details()]
        await adapter.health(recheck=False)
        return first, [row["id"] for row in adapter.account.details()], adapter.addons.details()

    def mock(router):
        router.get(USAGE).mock(side_effect=[
            httpx.Response(200, json=USAGE_BODY),
            httpx.Response(500),
        ])
    first, second, configured = run(scenario, shared, mock)
    assert "google_tagging" in first and first == second
    assert {row["id"] for row in configured} == {"imageGeneration", "imageToVideo"}


def test_google_tagging_returns_the_analysis_and_a_restart_can_read_it(tmp_path):
    shared = settings(tmp_path)
    analysis = {"tags": [{"tag": "cat", "confidence": 0.9}]}

    async def scenario(adapter):
        await adapter.health(recheck=False)
        request = job("image.analyze", "cloudinary/google-tagging")
        submitted = await adapter.submit(request.model, request)
        state = await adapter.status(submitted.jobId)
        again = await adapter.status(submitted.jobId)
        return submitted.jobId, state, again

    def mock(router):
        router.get(USAGE).respond(200, json=USAGE_BODY)
        router.get(ADMIN_IMAGE).respond(200, json={"asset_id": "asset-1", "width": 10, "height": 10, "bytes": 10})
        router.post(f"{ANALYZE}/google_tagging").respond(200, json={"data": {"analysis": analysis}})
    job_id, state, again = run(scenario, shared, mock)
    assert state.status == "succeeded" and state.results is None and state.analysis == analysis
    assert again.analysis == analysis
    fresh = run(lambda a: a.status(job_id), shared)
    assert fresh.analysis == analysis


def test_ai_vision_requires_a_prompt(tmp_path):
    async def scenario(adapter):
        await adapter.health(recheck=False)
        await adapter.submit("cloudinary/ai-vision", job("image.analyze", "cloudinary/ai-vision"))
    with pytest.raises(ProblemError) as info:
        run(scenario, settings(tmp_path), lambda r: r.get(USAGE).respond(200, json=USAGE_BODY))
    assert info.value.code == "invalid_request"


def test_imagga_tagging_uses_explicit_and_keeps_the_tags(tmp_path):
    async def scenario(adapter):
        await adapter.health(recheck=False)
        submitted = await adapter.submit("cloudinary/imagga-tagging", job("image.analyze", "cloudinary/imagga-tagging"))
        return await adapter.status(submitted.jobId)

    def mock(router):
        router.get(USAGE).respond(200, json=USAGE_BODY)
        router.post(EXPLICIT).respond(200, json={"tags": ["cat"], "info": {"categorization": {"imagga_tagging": {"data": []}}}})
    state = run(scenario, settings(tmp_path), mock)
    assert state.analysis["tags"] == ["cat"] and "imagga_tagging" in state.analysis["categorization"]


def test_viesus_and_imagga_crop_are_signed_deliveries(tmp_path):
    async def scenario(adapter):
        await adapter.health(recheck=False)
        enhanced = await adapter.submit("cloudinary/viesus-correct", job("image.enhance", "cloudinary/viesus-correct"))
        cropped = await adapter.submit("cloudinary/imagga-crop", job("image.crop", "cloudinary/imagga-crop", {"aspectRatio": "16:9"}))
        return decode_url_job(enhanced.jobId), decode_url_job(cropped.jobId)
    enhanced, cropped = run(scenario, settings(tmp_path), lambda r: r.get(USAGE).respond(200, json=USAGE_BODY))
    assert "/e_viesus_correct/" in enhanced and enhanced.endswith(f"lenora/{IMAGE_REF.split('/')[-1]}.png")
    assert "/ar_16:9,c_fill,g_imagga_crop/" in cropped


def test_an_unsubscribed_analysis_model_is_refused(tmp_path):
    async def scenario(adapter):
        await adapter.submit("cloudinary/google-tagging", job("image.analyze", "cloudinary/google-tagging"))
    with pytest.raises(ProblemError) as info:
        run(scenario, settings(tmp_path))
    assert info.value.code == "provider_unavailable"
