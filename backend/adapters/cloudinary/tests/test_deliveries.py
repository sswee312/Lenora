import base64
import json

import httpx
import pytest

from cld import ADMIN_IMAGE, ADMIN_VIDEO, SECRET, UUID, VIDEO_REF, admin, job, run, settings
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput, ImageEditParams
from lenora_adapter_cloudinary import signed_url
from lenora_adapter_cloudinary.delivery import edit_transformation
from lenora_backend.jobids import sign_job


def url_of(job_id: str) -> str:
    encoded = job_id.removeprefix("url:")
    return base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()


@pytest.mark.parametrize("params, transformation", [
    ({"op": "fill", "aspectRatio": "16:9"}, "ar_16:9,b_gen_fill,c_pad"),
    ({"op": "replace", "from": "the cat", "to": "a dog"}, "e_gen_replace:from_the%20cat;to_a%20dog"),
    ({"op": "remove", "prompt": "the cup"}, "e_gen_remove:prompt_the%20cup"),
    ({"op": "recolor", "prompt": "car", "color": "#1E90FF"}, "e_gen_recolor:prompt_car;to-color_1e90ff"),
    ({"op": "backgroundReplace"}, "e_gen_background_replace"),
    ({"op": "backgroundReplace", "prompt": "a beach"}, "e_gen_background_replace:prompt_a%20beach"),
    ({"op": "restore"}, "e_gen_restore"),
    ({"op": "remove", "prompt": "it's"}, "e_gen_remove:prompt_it%27s"),
])
def test_edit_transformations(params, transformation):
    assert edit_transformation(ImageEditParams.model_validate(params).root) == transformation


@pytest.mark.parametrize("op, credits", [
    ({"op": "fill", "aspectRatio": "1:1"}, 0.05), ({"op": "replace", "from": "a", "to": "b"}, 0.12),
    ({"op": "remove", "prompt": "a"}, 0.05), ({"op": "recolor", "prompt": "a", "color": "#000000"}, 0.05),
    ({"op": "backgroundReplace"}, 0.23), ({"op": "restore"}, 0.1),
])
def test_edit_submit_signs_url_and_estimates(op, credits):
    submitted = run(lambda a: a.submit("cloudinary/generative-edit", job("image.edit", "cloudinary/generative-edit", op)))
    expected = signed_url("demo", "image", edit_transformation(ImageEditParams.model_validate(op).root), f"lenora/{UUID}.png", SECRET)
    assert url_of(submitted.jobId) == expected
    assert submitted.estimate.amount == pytest.approx(credits)


@pytest.mark.parametrize("width, height, ok, credits", [
    (2048, 2048, True, 0.1), (2049, 2048, False, None), (499, 500, True, 0.01), (500, 500, True, 0.1),
])
def test_upscale_pixel_limit_and_estimate(width, height, ok, credits):
    request = job("image.upscale", "cloudinary/upscale")
    mock = lambda r: admin(r, width=width, height=height)
    if ok:
        submitted = run(lambda a: a.submit(request.model, request), mock=mock)
        assert "/e_upscale/" in url_of(submitted.jobId)
        assert submitted.estimate.amount == pytest.approx(credits)
    else:
        with pytest.raises(ProblemError) as info:
            run(lambda a: a.submit(request.model, request), mock=mock)
        assert info.value.code == "input_too_large"


@pytest.mark.parametrize("width, height", [(None, 500), (500, None), (None, None), (0, 500), (500, -1)])
def test_upscale_refuses_missing_or_nonpositive_dimensions(width, height):
    request = job("image.upscale", "cloudinary/upscale")
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.submit(request.model, request), mock=lambda r: admin(r, width=width, height=height))
    assert info.value.code == "invalid_request"


def test_missing_asset_is_invalid_request():
    request = job("image.upscale", "cloudinary/upscale")
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.submit(request.model, request), mock=lambda r: r.get(ADMIN_IMAGE).respond(404))
    assert info.value.code == "invalid_request"


def test_reframe_at_the_cap_is_an_on_the_fly_url():
    request = job("video.reframe", "cloudinary/reframe", {"aspectRatio": "9:16"}, [AssetInput(assetRef=VIDEO_REF)])
    submitted = run(lambda a: a.submit(request.model, request), mock=lambda r: admin(r, bytes_=41943040, duration=2.4, video=True))
    assert url_of(submitted.jobId) == signed_url("demo", "video", "ar_9:16,c_fill,g_auto", f"lenora/{UUID}.mp4", SECRET)
    assert submitted.estimate.amount == pytest.approx(0.042)


def test_reframe_above_the_cap_runs_eager_and_polls_derived():
    request = job("video.reframe", "cloudinary/reframe", {"aspectRatio": "9:16"}, [AssetInput(assetRef=VIDEO_REF)])
    sent = []

    def mock(r):
        admin(r, bytes_=41943041, duration=60, video=True)
        r.post("https://api.cloudinary.com/v1_1/demo/video/explicit").mock(
            side_effect=lambda req: sent.append(req.content.decode()) or httpx.Response(200, json={"batch_id": "b"}))

    async def scenario(a):
        submitted = await a.submit(request.model, request)
        return submitted, await a.status(submitted.jobId)
    submitted, state = run(scenario, mock=mock)
    assert submitted.jobId.startswith("eager:") and "eager_async=true" in sent[0] and "signature=" in sent[0]
    assert all(f"{k}=" in sent[0] for k in ("public_id", "eager", "timestamp")) and SECRET not in sent[0]
    assert state.status == "running" and state.retryAfter == 30


TRANSFORMATION = "ar_9:16,c_fill,g_auto"
PUBLIC_ID = f"lenora/{UUID}"


def raw_id(payload) -> str:
    return sign_job("eager", json.dumps(payload), SECRET)


def test_eager_job_succeeds_once_derived_exists():
    from lenora_adapter_cloudinary import eager
    job_id = eager.encode(PUBLIC_ID, TRANSFORMATION, 1000, SECRET)
    body = {"asset_id": "a", "bytes": 1, "derived": [{"transformation": TRANSFORMATION}]}
    state = run(lambda a: a.status(job_id), mock=lambda r: r.get(ADMIN_VIDEO).respond(200, json=body))
    assert state.status == "succeeded"
    assert str(state.results[0].url) == signed_url("demo", "video", TRANSFORMATION, f"lenora/{UUID}.mp4", SECRET)


@pytest.mark.parametrize("now, status", [(1000 + 1800, "running"), (1000 + 1801, "failed")])
def test_eager_job_fails_after_the_deadline(now, status):
    from lenora_adapter_cloudinary import eager
    job_id = eager.encode(PUBLIC_ID, TRANSFORMATION, 1000, SECRET)
    state = run(lambda a: a.status(job_id), mock=lambda r: r.get(ADMIN_VIDEO).respond(200, json={"asset_id": "a", "bytes": 1, "derived": []}), clock=lambda: now)
    assert state.status == status
    if status == "failed":
        assert (state.error.code, state.error.retryable) == ("provider_error", True)


@pytest.mark.parametrize("job_id", [
    "eager:%%",
    raw_id({"p": "other/x", "t": TRANSFORMATION, "s": 1}),
    raw_id({"p": "lenora/../..", "t": TRANSFORMATION, "s": 1}),
    raw_id({"p": "lenora/abc", "t": TRANSFORMATION, "s": 1}),
    raw_id({"p": "lenora/a?x=1", "t": TRANSFORMATION, "s": 1}),
    raw_id({"p": "lenora/a#x", "t": TRANSFORMATION, "s": 1}),
    raw_id({"p": PUBLIC_ID, "t": "ar_2:1,c_fill,g_auto", "s": 1}),
    raw_id({"p": PUBLIC_ID, "t": "e_gen_restore", "s": 1}),
    raw_id({"p": PUBLIC_ID, "t": TRANSFORMATION, "s": "1"}),
    raw_id({"p": PUBLIC_ID, "t": TRANSFORMATION, "s": True}),
    raw_id({"p": PUBLIC_ID, "t": TRANSFORMATION}),
    raw_id([PUBLIC_ID, TRANSFORMATION, 1]),
    raw_id("text"),
])
def test_eager_rejects_foreign_ids(job_id):
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.status(job_id))
    assert info.value.code == "not_found"


def forged_eager_ids() -> list[str]:
    from lenora_adapter_cloudinary import eager
    good = eager.encode(PUBLIC_ID, TRANSFORMATION, 1000, SECRET)
    payload, signature = good.removeprefix("eager:").split(".")
    raw = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)).decode()
    return [
        f"eager:{payload}", f"eager:{payload}x.{signature}", f"eager:{payload}.{signature[:-1]}A",
        eager.encode(PUBLIC_ID, TRANSFORMATION, 1000, "other-secret"),
        sign_job("publish", raw, SECRET).replace("publish:", "eager:", 1),
        "eager:" + base64.urlsafe_b64encode(raw.encode()).decode().rstrip("="),
    ]


@pytest.mark.parametrize("job_id", forged_eager_ids())
def test_unsigned_or_tampered_eager_ids_are_not_found_without_a_lookup(job_id):
    route = {}

    def mock(r):
        route["get"] = r.get(ADMIN_VIDEO).respond(200, json={"asset_id": "a", "bytes": 1, "derived": []})
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.status(job_id), mock=mock)
    assert info.value.code == "not_found" and not route["get"].called


def test_eager_job_for_a_deleted_video_fails_without_retry():
    from lenora_adapter_cloudinary import eager
    job_id = eager.encode(PUBLIC_ID, TRANSFORMATION, 1000, SECRET)
    state = run(lambda a: a.status(job_id), mock=lambda r: r.get(ADMIN_VIDEO).respond(404), clock=lambda: 1100.0)
    assert (state.status, state.error.code, state.error.retryable) == ("failed", "provider_error", False)


@pytest.mark.parametrize("status", [400, 422])
def test_eager_invalid_lookup_is_not_a_deleted_video(status):
    from lenora_adapter_cloudinary import eager
    job_id = eager.encode(PUBLIC_ID, TRANSFORMATION, 1000, SECRET)
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.status(job_id), mock=lambda r: r.get(ADMIN_VIDEO).respond(status, json={"error": {"message": "bad"}}))
    assert info.value.code == "invalid_request"


@pytest.mark.parametrize("size, eager_used", [(104857600, True), (104857601, False)])
def test_reframe_is_capped_at_the_plan_video_limit(size, eager_used):
    request = job("video.reframe", "cloudinary/reframe", {"aspectRatio": "9:16"}, [AssetInput(assetRef=VIDEO_REF)])
    calls = []

    def mock(r):
        admin(r, bytes_=size, duration=60, video=True)
        r.post("https://api.cloudinary.com/v1_1/demo/video/explicit").mock(
            side_effect=lambda req: calls.append(req) or httpx.Response(200, json={}))

    async def scenario(a):
        try:
            return await a.submit(request.model, request), a.budget.usage()["used"]
        except ProblemError as error:
            return error, a.budget.usage()["used"]
    result, used = run(scenario, mock=mock)
    if eager_used:
        assert result.jobId.startswith("eager:") and len(calls) == 1 and used > 0
    else:
        assert result.code == "input_too_large" and not calls and used == 0


def test_reframe_rejects_image_refs():
    request = job("video.reframe", "cloudinary/reframe", {"aspectRatio": "9:16"})
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.submit(request.model, request))
    assert info.value.code == "invalid_request"


def test_reframe_result_is_mp4():
    request = job("video.reframe", "cloudinary/reframe", {"aspectRatio": "1:1"}, [AssetInput(assetRef=VIDEO_REF)])

    async def scenario(a):
        return await a.status((await a.submit(request.model, request)).jobId)

    def mock(r):
        admin(r, duration=1.0, video=True)
        r.get(url__startswith="https://res.cloudinary.com/demo/video/").respond(206)
    state = run(scenario, mock=mock)
    assert state.results[0].contentType == "video/mp4" and state.results[0].fileExtension == "mp4"


def test_rate_limited_delivery_keeps_running():
    request = job("image.edit", "cloudinary/generative-edit", {"op": "restore"})

    async def scenario(a):
        return await a.status((await a.submit(request.model, request)).jobId)
    state = run(scenario, mock=lambda r: r.get(url__startswith="https://res.cloudinary.com/").respond(420))
    assert state.status == "running" and state.retryAfter == 30


def submitted_edit_url() -> str:
    submitted = run(lambda a: a.submit("cloudinary/generative-edit", job("image.edit", "cloudinary/generative-edit", {"op": "restore"})))
    return url_of(submitted.jobId)


def url_job(url: str) -> str:
    return "url:" + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


@pytest.mark.parametrize("tamper", [
    lambda u: u.replace("/lenora/", "/../other-cloud/image/upload/lenora/"),
    lambda u: u.replace("/upload/", "/fetch/"),
    lambda u: u.replace("s--", "s--x", 1).replace("--/", "-/", 1),
    lambda u: u.replace("e_gen_restore", "e_gen_remove:prompt_x"),
])
def test_status_rejects_urls_not_signed_by_this_adapter(tamper):
    job_id = url_job(tamper(submitted_edit_url()))
    routes = []
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.status(job_id), mock=lambda r: routes.append(r.get(url__regex=".*").respond(200)))
    assert info.value.code == "not_found" and not routes[0].called


@pytest.mark.parametrize("status, code", [(429, "rate_limited"), (500, "provider_unavailable"), (503, "provider_unavailable")])
def test_transient_delivery_errors_are_not_terminal(status, code):
    url = submitted_edit_url()
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.status(url_job(url)), mock=lambda r: r.get(url).respond(status))
    assert info.value.code == code and info.value.retryable


def test_delivery_client_error_is_terminal_failure():
    url = submitted_edit_url()
    state = run(lambda a: a.status(url_job(url)), mock=lambda r: r.get(url).respond(400, headers={"X-Cld-Error": "Bad transformation"}))
    assert (state.status, state.error.message) == ("failed", "Bad transformation")
