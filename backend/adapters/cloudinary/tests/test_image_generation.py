import asyncio
import json

import httpx
import pytest
import respx

from cld import GEN, IMAGE_REF, admin, gen_task, job, run, settings
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput
from lenora_adapter_cloudinary import CloudinaryAdapter

MODEL = "cloudinary/image-generation"


def generate(params=None, inputs=None):
    return job("image.generate", MODEL, params or {"prompt": "a lighthouse"}, inputs or [])


def model_ids(adapter) -> set[str]:
    return {m.id for m in adapter.models()}


def listed(s) -> set[str]:
    return run(lambda a: asyncio.sleep(0, model_ids(a)), s)


@pytest.mark.parametrize("mode, is_listed", [("auto", True), ("on", True), ("off", False)])
def test_mode_decides_the_listing(mode, is_listed, tmp_path):
    assert (MODEL in listed(settings(tmp_path, image_generation=mode))) is is_listed


def test_text_to_image_body_and_job_id(tmp_path):
    sent = []

    def mock(r):
        def record(req):
            sent.append(json.loads(req.content))
            return httpx.Response(202, json={"data": {"status": "pending", "task_id": f"t{len(sent)}"}})
        r.post(f"{GEN}/text_to_image").mock(side_effect=record)
    request = generate({"prompt": "a lighthouse", "aspectRatio": "16:9", "count": 2, "seed": 7})
    submitted = run(lambda a: a.submit(MODEL, request), settings(tmp_path), mock)
    assert submitted.jobId == "gen:t1.t2" and submitted.estimate.amount == pytest.approx(2.0)
    assert sent[0]["image_size"] == {"aspect_ratio": "16:9"} and sent[0]["seed"] == 7 and sent[0]["async"] is True
    assert sent[0]["target"]["public_id"].startswith("lenora/")
    assert sent[0]["target"]["public_id"] != sent[1]["target"]["public_id"]


def test_references_switch_to_image_to_image_by_asset_id(tmp_path):
    sent = []

    def mock(r):
        admin(r, asset_id="ref-asset")
        r.post(f"{GEN}/image_to_image").mock(side_effect=lambda req: (
            sent.append(json.loads(req.content)) or httpx.Response(202, json={"data": {"task_id": "t1"}})))
    run(lambda a: a.submit(MODEL, generate(inputs=[AssetInput(assetRef=IMAGE_REF, role="reference")])), settings(tmp_path), mock)
    assert sent[0]["reference_images"] == [{"source_type": "managed_asset", "asset_id": "ref-asset"}]


@pytest.mark.parametrize("first, second, status", [
    ("completed", "processing", "running"), ("completed", "completed", "succeeded"), ("failed", "completed", "failed"),
])
def test_multi_task_status(first, second, status, tmp_path):
    def mock(r):
        r.get(f"{GEN}/tasks/t1").respond(200, json=gen_task(first))
        r.get(f"{GEN}/tasks/t2").respond(200, json=gen_task(second))
    state = run(lambda a: a.status("gen:t1.t2"), settings(tmp_path), mock)
    assert state.status == status
    if status == "succeeded":
        assert len(state.results) == 2 and state.results[0].fileExtension == "png"
    if status == "failed":
        assert state.error.message == "Prompt rejected by moderation."


def test_results_at_the_alternate_documented_location(tmp_path):
    body = {"data": {"status": "completed", "assets": [
        {"format": "jpeg", "storage": {"secure_url": "https://res.cloudinary.com/demo/image/upload/a.jpg"}}]}}
    state = run(lambda a: a.status("gen:t1"), settings(tmp_path), lambda r: r.get(f"{GEN}/tasks/t1").respond(200, json=body))
    assert state.results[0].contentType == "image/jpeg" and state.results[0].fileExtension == "jpg"


def test_completed_without_a_url_fails_cleanly(tmp_path):
    body = {"data": {"status": "completed", "result": {"assets": [{"format": "png", "storage": {}}]}}}
    state = run(lambda a: a.status("gen:t1"), settings(tmp_path), lambda r: r.get(f"{GEN}/tasks/t1").respond(200, json=body))
    assert state.status == "failed"


@pytest.mark.parametrize("status", [401, 403])
def test_auto_learns_a_refusal_and_keeps_it_after_restart(status, tmp_path):
    s = settings(tmp_path)

    async def scenario(a):
        with pytest.raises(ProblemError) as info:
            await a.submit(MODEL, generate())
        return info.value, model_ids(a)
    error, ids = run(scenario, s, lambda r: r.post(f"{GEN}/text_to_image").respond(status, json={"error": {"message": "no"}}))
    assert error.code == "provider_unavailable" and not error.retryable and "Image Generation" in error.detail
    assert MODEL not in ids and MODEL not in listed(s)


def test_a_refusal_while_polling_fails_the_job_and_is_learned(tmp_path):
    s = settings(tmp_path)

    async def scenario(a):
        state = await a.status("gen:t1")
        return state, model_ids(a)
    state, ids = run(scenario, s, lambda r: r.get(f"{GEN}/tasks/t1").respond(403))
    assert state.status == "failed" and state.error.code == "provider_unavailable" and not state.error.retryable
    assert "Image Generation" in state.error.message and MODEL not in ids


@pytest.mark.parametrize("status, code", [(500, "provider_error"), (502, "provider_error"), (429, "rate_limited")])
def test_other_failures_are_not_learned(status, code, tmp_path):
    s = settings(tmp_path)

    async def scenario(a):
        with pytest.raises(ProblemError) as info:
            await a.submit(MODEL, generate())
        return info.value.code, model_ids(a)
    found, ids = run(scenario, s, lambda r: r.post(f"{GEN}/text_to_image").respond(status))
    assert found == code and MODEL in ids


def test_on_mode_never_learns(tmp_path):
    s = settings(tmp_path, image_generation="on")

    async def scenario(a):
        with pytest.raises(ProblemError):
            await a.submit(MODEL, generate())
        return model_ids(a)
    assert MODEL in run(scenario, s, lambda r: r.post(f"{GEN}/text_to_image").respond(403))


def test_off_mode_refuses_without_calling_cloudinary(tmp_path):
    with respx.mock(assert_all_called=False) as router:
        route = router.post(url__startswith=GEN).respond(202)

        async def go():
            async with httpx.AsyncClient() as http:
                with pytest.raises(ProblemError) as info:
                    await CloudinaryAdapter(settings(tmp_path, image_generation="off"), http).submit(MODEL, generate())
                return info.value.code
        assert asyncio.run(go()) == "provider_unavailable" and not route.called


def test_failed_submit_refunds_the_budget(tmp_path):
    async def scenario(a):
        with pytest.raises(ProblemError):
            await a.submit(MODEL, generate())
        return a.budget.usage()["used"]
    assert run(scenario, settings(tmp_path, daily_credit_budget=2.0),
               lambda r: r.post(f"{GEN}/text_to_image").respond(500)) == 0


def test_partial_multi_image_submit_keeps_only_the_sent_tasks(tmp_path):
    def mock(r):
        r.post(f"{GEN}/text_to_image").mock(side_effect=[
            httpx.Response(202, json={"data": {"task_id": "t1", "status": "pending"}}), httpx.Response(500)])

    async def scenario(a):
        with pytest.raises(ProblemError):
            await a.submit(MODEL, generate({"prompt": "x", "count": 3}))
        return a.budget.usage()["used"]
    assert run(scenario, settings(tmp_path), mock) == pytest.approx(1.0)


def test_recheck_lists_the_model_again(tmp_path):
    s = settings(tmp_path)

    async def scenario(a):
        with pytest.raises(ProblemError):
            await a.submit(MODEL, generate())
        before = model_ids(a)
        await a.health(recheck=True)
        return before, model_ids(a)
    before, after = run(scenario, s, lambda r: r.post(f"{GEN}/text_to_image").respond(403))
    assert MODEL not in before and MODEL in after


def test_network_failure_is_not_learned(tmp_path):
    s = settings(tmp_path)

    async def scenario(a):
        with pytest.raises(ProblemError) as info:
            await a.submit(MODEL, generate())
        return info.value, model_ids(a)
    error, ids = run(scenario, s, lambda r: r.post(f"{GEN}/text_to_image").mock(side_effect=httpx.ConnectError("down")))
    assert error.code == "provider_unavailable" and error.retryable and MODEL in ids
