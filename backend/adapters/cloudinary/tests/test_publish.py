import asyncio
from urllib.parse import parse_qs

import httpx
import pytest

from cld import ADMIN_VIDEO, API, CLOUD, SECRET, UUID, VIDEO_REF, job, run, settings
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput
from lenora_adapter_cloudinary import publish
from lenora_adapter_cloudinary.delivery import signed_url

EXPLICIT = f"{API}/v1_1/{CLOUD}/video/explicit"
DESTROY = f"{API}/v1_1/{CLOUD}/video/destroy"
USAGE = f"{API}/v1_1/{CLOUD}/usage"
ALL = ["sp_auto:maxres_1080p/m3u8", "so_auto/jpg", "ar_9:16,c_fill,g_auto/mp4", "e_preview:duration_15/mp4"]


def publish_job(outputs=None):
    return job("video.publish", "cloudinary/publish", {"outputs": outputs or {}}, [AssetInput(assetRef=VIDEO_REF)])


def shaped(output: str) -> dict:
    """An Admin API derived entry as Cloudinary really reports it: only mp4 drops the extension."""
    transformation, _, extension = output.rpartition("/")
    return {"transformation": transformation, "format": "mp4"} if extension == "mp4" else {
        "transformation": output, "format": extension}


NOISE = [{"transformation": "sp_auto:maxres_1080p/mpd", "format": "mpd"},
         {"transformation": "sp_auto:maxres_1080p/pg_1/mp4dv", "format": "mp4"},
         {"transformation": "sp_auto:maxres_1080p/pg_2/m3u8", "format": "m3u8"}]


def video(router, *, duration=20.0, bytes_=1000, derived=(), fmt="mp4", extra=()):
    return router.get(ADMIN_VIDEO).respond(200, json={
        "asset_id": "a1", "bytes": bytes_, "duration": duration, "format": fmt,
        "derived": [shaped(t) for t in derived] + list(extra)})


def form(route) -> dict[str, str]:
    return {k: v[0] for k, v in parse_qs(route.calls.last.request.content.decode()).items()}


def submitted(outputs=None, mock=None, settings_=None, clock=None):
    return run(lambda a: a.submit("cloudinary/publish", publish_job(outputs)), settings_, mock=mock, clock=clock)


def test_submit_requests_every_output_in_one_eager_call():
    routes = {}

    def mock(r):
        video(r)
        routes["explicit"] = r.post(EXPLICIT).respond(200, json={})
    job_ = submitted({"vertical": "9:16", "teaserSeconds": 15}, mock)
    sent = form(routes["explicit"])
    assert sent["eager"] == "|".join(ALL) and sent["eager_async"] == "true" and sent["public_id"] == f"lenora/{UUID}"
    assert "signature" in sent and SECRET not in routes["explicit"].calls.last.request.content.decode()
    assert job_.jobId.startswith("publish:")
    assert job_.estimate.amount == pytest.approx((8 * 20 + 1 + 14 * 20 + 2 * 20) / 1000)


def test_derived_outputs_are_not_requested_or_billed_again():
    routes = {}

    def mock(r):
        video(r, derived=ALL[:2])
        routes["explicit"] = r.post(EXPLICIT).respond(200, json={})
    job_ = submitted({"teaserSeconds": 15}, mock)
    assert form(routes["explicit"])["eager"] == "e_preview:duration_15/mp4"
    assert job_.estimate.amount == pytest.approx(2 * 20 / 1000)


def test_nothing_is_requested_when_every_output_exists():
    routes = {}

    def mock(r):
        video(r, derived=ALL[:2])
        routes["explicit"] = r.post(EXPLICIT).respond(200, json={})
    assert submitted(None, mock).estimate.amount == 0 and not routes["explicit"].called


@pytest.mark.parametrize("duration, teaser", [(15.0, 15), (10.0, 15), (0.0, 5)])
def test_teaser_must_be_shorter_than_the_video(duration, teaser):
    with pytest.raises(ProblemError) as info:
        submitted({"teaserSeconds": teaser}, lambda r: video(r, duration=duration))
    assert info.value.code == "invalid_request"


def test_video_over_the_limit_is_refused():
    with pytest.raises(ProblemError) as info:
        submitted(None, lambda r: video(r, bytes_=publish.MAX_BYTES + 1))
    assert info.value.code == "input_too_large"


def test_over_budget_is_refused_before_cloudinary(tmp_path):
    routes = {}

    def mock(r):
        video(r)
        routes["explicit"] = r.post(EXPLICIT).respond(200, json={})
    with pytest.raises(ProblemError) as info:
        submitted(None, mock, settings(tmp_path, daily_credit_budget=0.1))
    assert info.value.code == "quota_exceeded" and not routes["explicit"].called


def test_a_refused_eager_request_is_refunded(tmp_path):
    async def scenario(adapter):
        with pytest.raises(ProblemError):
            await adapter.submit("cloudinary/publish", publish_job())
        return adapter.budget.usage()["used"]

    def mock(r):
        video(r)
        r.post(EXPLICIT).respond(400, json={"error": {"message": "Bad eager"}})
    assert run(scenario, settings(tmp_path, daily_credit_budget=5), mock=mock) == 0


def status_of(job_id, mock, clock=None):
    return run(lambda a: a.status(job_id), mock=mock, clock=clock)


def submitted_id(outputs=None, at=1000.0):
    def mock(r):
        video(r)
        r.post(EXPLICIT).respond(200, json={})
    return submitted(outputs, mock, clock=lambda: at).jobId


def test_pending_outputs_keep_the_job_running_without_results():
    state = status_of(submitted_id(), lambda r: video(r, derived=ALL[:1]), clock=lambda: 1100.0)
    assert (state.status, state.results, state.retryAfter) == ("running", None, publish.RETRY_AFTER)


def test_ready_job_lists_every_role_with_signed_urls():
    state = status_of(submitted_id({"vertical": "9:16", "teaserSeconds": 15}), lambda r: video(r, derived=ALL))
    by_role = {r.role: r for r in state.results}
    assert state.status == "succeeded" and state.failedOutputs is None
    assert sorted(by_role) == ["download", "poster", "stream", "teaser", "vertical"]
    assert str(by_role["stream"].url) == signed_url(CLOUD, "video", "sp_auto:maxres_1080p", f"lenora/{UUID}.m3u8", SECRET)
    assert str(by_role["download"].url) == signed_url(CLOUD, "video", "", f"lenora/{UUID}.mp4", SECRET)
    assert by_role["stream"].contentType == "application/vnd.apple.mpegurl" and by_role["poster"].fileExtension == "jpg"


def test_derived_entries_with_a_separate_format_count_as_ready():
    def mock(r):
        r.get(ADMIN_VIDEO).respond(200, json={"asset_id": "a1", "bytes": 1, "duration": 20.0, "format": "mp4", "derived": [
            {"transformation": "sp_auto:maxres_1080p", "format": "m3u8"}, {"transformation": "so_auto", "format": "jpg"}]})
    assert status_of(submitted_id(), mock).status == "succeeded"


def test_real_derived_shapes_with_extra_stream_entries_are_ready():
    state = status_of(submitted_id({"vertical": "9:16", "teaserSeconds": 15}),
                      lambda r: video(r, derived=ALL, extra=NOISE))
    assert state.status == "succeeded" and len(state.results) == 5


def test_extra_entries_never_stand_in_for_a_requested_output():
    noise_only = [*NOISE, {"transformation": "ar_9:16,c_fill,g_auto,q_auto", "format": "mp4"},
                  {"transformation": "sp_auto:maxres_1080p", "format": "mpd"}, {"transformation": "so_auto/png", "format": "png"}]
    state = status_of(submitted_id({"vertical": "9:16"}), lambda r: video(r, extra=noise_only), clock=lambda: 1100.0)
    assert state.status == "running" and state.results is None


@pytest.mark.parametrize("entry, expected", [
    ({"transformation": "e_preview:duration_15", "format": "mp4"}, True),
    ({"transformation": "e_preview:duration_15/mp4", "format": "mp4"}, True),
    ({"transformation": "e_preview:duration_15", "format": "webm"}, False),
    ({"transformation": "e_preview:duration_15,q_auto", "format": "mp4"}, False),
    ({"transformation": "e_preview:duration_5", "format": "mp4"}, False),
])
def test_output_matches_derived_by_exact_transformation(entry, expected):
    derived = ((entry["transformation"], entry["format"]),)
    assert publish.Output("teaser", "e_preview:duration_15", "mp4").is_derived(derived) is expected


def test_noise_does_not_hide_pending_outputs_from_submit():
    routes = {}

    def mock(r):
        video(r, derived=ALL[:2], extra=NOISE)
        routes["explicit"] = r.post(EXPLICIT).respond(200, json={})
    submitted({"teaserSeconds": 15}, mock)
    assert form(routes["explicit"])["eager"] == "e_preview:duration_15/mp4"


def test_an_output_that_times_out_is_reported_while_the_rest_succeed():
    state = status_of(submitted_id({"teaserSeconds": 15}), lambda r: video(r, derived=ALL[:2]),
                      clock=lambda: 1000.0 + publish.EAGER_TIMEOUT_SECONDS + 1)
    assert state.status == "succeeded"
    assert [(f.role, f.code) for f in state.failedOutputs] == [("teaser", "provider_error")]


def test_a_stream_that_times_out_fails_the_job():
    state = status_of(submitted_id(), lambda r: video(r, derived=ALL[1:2]),
                      clock=lambda: 1000.0 + publish.EAGER_TIMEOUT_SECONDS + 1)
    assert state.status == "failed" and state.error.code == "provider_error"


def test_a_deleted_video_fails_the_job():
    state = status_of(submitted_id(), lambda r: r.get(ADMIN_VIDEO).respond(404))
    assert state.status == "failed"


def tampered(job_id: str) -> list[str]:
    payload, signature = job_id.removeprefix("publish:").split(".")
    return [f"publish:{payload}x.{signature}", f"publish:{payload}.{signature[:-1]}A", f"publish:{payload}",
            "publish:", "publish:%%%.x", publish.encode(publish.decode(job_id, SECRET), "other-secret")]


def signed_with_fields(**fields) -> str:
    base = dict(public_id=f"lenora/{UUID}", extension="mp4", vertical=None, teaser=None, submitted_at=1000)
    return publish.encode(publish.PublishJob(**{**base, **fields}), SECRET)


@pytest.mark.parametrize("fields", [
    {"public_id": "lenora/../../other"}, {"public_id": "other/x"}, {"public_id": f"video/lenora/{UUID}"},
    {"extension": "exe"}, {"extension": "m3u8"}, {"vertical": "16:9"}, {"vertical": "9:16,q_1"},
    {"teaser": 4}, {"teaser": 31}, {"teaser": True}, {"teaser": "15"},
    {"submitted_at": "1000"}, {"submitted_at": 1.5}, {"submitted_at": True},
])
def test_validly_signed_ids_with_invalid_fields_are_unknown(fields):
    assert publish.decode(signed_with_fields(**fields), SECRET) is None


def test_forged_publish_ids_are_unknown():
    for job_id in tampered(submitted_id()):
        with pytest.raises(ProblemError) as info:
            status_of(job_id, lambda r: video(r, derived=ALL))
        assert info.value.code == "not_found", job_id


@pytest.mark.parametrize("response, limit", [
    (httpx.Response(200, json={"media_limits": {"video_max_size_bytes": 50_000_000}}), 50_000_000),
    (httpx.Response(200, json={"media_limits": {"video_max_size_bytes": 2_000_000_000}}), publish.MAX_BYTES),
    (httpx.Response(200, json={}), publish.MAX_BYTES),
    (httpx.Response(500), publish.MAX_BYTES),
])
def test_start_reads_the_account_video_limit(response, limit):
    async def scenario(adapter):
        await adapter.start()
        return next(m for m in adapter.models() if m.id == "cloudinary/publish").inputs.maxBytes
    assert run(scenario, mock=lambda r: r.get(USAGE).mock(return_value=response)) == limit


def test_publish_model_is_deletable_and_lists_its_choices():
    model = next(m for m in run(lambda a: asyncio.sleep(0, a.models())) if m.id == "cloudinary/publish")
    assert model.kind == "video.publish" and model.deletable
    assert model.ui == {"publish": {"verticalAspects": ["9:16", "1:1", "4:5"], "teaserSeconds": {"min": 5, "max": 30}}}


def test_delete_destroys_and_invalidates():
    routes = {}

    def mock(r):
        routes["destroy"] = r.post(DESTROY).respond(200, json={"result": "ok"})
    run(lambda a: a.delete_asset("cloudinary/publish", VIDEO_REF), mock=mock)
    sent = form(routes["destroy"])
    assert (sent["public_id"], sent["invalidate"]) == (f"lenora/{UUID}", "true") and "signature" in sent


def test_deleting_twice_is_not_found():
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.delete_asset("cloudinary/publish", VIDEO_REF),
            mock=lambda r: r.post(DESTROY).respond(200, json={"result": "not found"}))
    assert info.value.code == "not_found"


@pytest.mark.parametrize("ref", ["image/upload/lenora/" + UUID, "video/upload/other/x", "../x"])
def test_delete_rejects_foreign_refs(ref):
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.delete_asset("cloudinary/publish", ref))
    assert info.value.code == "invalid_request"
