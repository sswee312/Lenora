import asyncio
import base64
import json
from pathlib import Path

import httpx
import pytest
import respx

from cld import API, DELIVERY, GEN, I2V, SECRET, UUID, gen_task, i2v_job, job, run, settings
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput, JobRequest, UploadRequest, UrlInput
from lenora_backend.testing.conformance import AdapterConformance
from lenora_adapter_cloudinary import CloudinaryAdapter, CloudinarySettings, sign_upload, signed_url


def test_signature_matches_cloudinary_documented_example():
    # Example from https://cloudinary.com/documentation/authentication_signatures
    params = {"eager": "w_400,h_300,c_pad|w_260,h_200,c_crop", "public_id": "sample_image", "timestamp": "1315060510"}
    assert sign_upload(params, "abcd") == "bfd09f95f331f558cbd1320e67aa8d488770583e"


def test_delivery_signature_matches_cloudinary_documented_example():
    # Example from https://cloudinary.com/documentation/delivery_url_signatures
    url = signed_url("demo", "image", "c_fill,w_300,h_250/e_grayscale", "sample-authenticated.png", "abcd")
    assert url == "https://res.cloudinary.com/demo/image/upload/s--iDy_JeBq--/c_fill,w_300,h_250/e_grayscale/sample-authenticated.png"


@pytest.mark.parametrize("content_type, resource", [("image/png", "image"), ("video/mp4", "video")])
def test_ticket_fields_and_asset_ref(content_type, resource):
    req = UploadRequest(model="cloudinary/reframe", contentType=content_type, byteCount=10, filename="a")
    ticket = run(lambda a: a.create_upload(req.model, req))
    fields = ticket.ticket.fields
    assert str(ticket.ticket.url) == f"https://api.cloudinary.com/v1_1/demo/{resource}/upload"
    assert set(fields) == {"api_key", "timestamp", "public_id", "signature"}
    assert ticket.assetRef == f"{resource}/upload/{fields['public_id']}"
    assert fields["signature"] == sign_upload({"public_id": fields["public_id"], "timestamp": fields["timestamp"]}, SECRET)
    assert SECRET not in ticket.model_dump_json()


def test_remove_background_url_is_signed():
    submitted = run(lambda a: a.submit("cloudinary/background-removal", job("image.removeBackground", "cloudinary/background-removal")))
    encoded = submitted.jobId.removeprefix("url:")
    url = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()
    assert url == signed_url("demo", "image", "e_background_removal", f"lenora/{UUID}.png", SECRET)
    assert submitted.estimate.amount == pytest.approx(0.075)


@pytest.mark.parametrize("ref", [
    "image/upload/other/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d",
    "image/upload/lenora/../../x",
    "video/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d",
])
def test_image_kinds_reject_foreign_asset_refs(ref):
    request = job("image.removeBackground", "cloudinary/background-removal", inputs=[AssetInput(assetRef=ref)])
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.submit(request.model, request))
    assert info.value.code == "invalid_request"


def test_submit_rejects_url_inputs():
    request = job("image.removeBackground", "cloudinary/background-removal", inputs=[UrlInput(url="https://example.com/a.png")])
    with pytest.raises(ProblemError):
        run(lambda a: a.submit(request.model, request))


@pytest.mark.parametrize("url", [
    "https://evil.example/x.png",
    "https://res.cloudinary.com/other-cloud/image/upload/x.png",
    "http://res.cloudinary.com/demo/image/upload/x.png",
])
def test_status_rejects_foreign_url(url):
    job_id = "url:" + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")
    with respx.mock(assert_all_called=False) as router:
        route = router.get(url__regex=".*").respond(200)
        with pytest.raises(ProblemError) as info:
            run(lambda a: a.status(job_id))
        assert info.value.code == "not_found" and not route.called


@pytest.mark.parametrize("job_id", ["url:%%%", "nope", "url:"])
def test_status_rejects_malformed_ids(job_id):
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.status(job_id))
    assert info.value.code == "not_found"


def test_disabled_without_keys(monkeypatch):
    from pydantic import ValidationError
    monkeypatch.setenv("LENORA_CLOUDINARY_API_KEY", "")
    with pytest.raises(ValidationError):
        CloudinarySettings()


def test_defaults(monkeypatch):
    monkeypatch.setenv("LENORA_CLOUDINARY_CLOUD_NAME", "demo")
    monkeypatch.setenv("LENORA_CLOUDINARY_API_KEY", "k")
    monkeypatch.setenv("LENORA_CLOUDINARY_API_SECRET", "s")
    s = CloudinarySettings()
    assert (s.on_the_fly_video_max_bytes, s.image_generation, s.image_to_video) == (41943040, "auto", "auto")
    assert (str(s.data_dir), s.daily_credit_budget) == (".data", None)


def test_data_dir_reads_the_shared_variable(monkeypatch, tmp_path):
    monkeypatch.setenv("LENORA_DATA_DIR", str(tmp_path))
    assert CloudinarySettings(cloud_name="d", api_key="k", api_secret="s").data_dir == tmp_path


def test_data_dir_argument_is_used(tmp_path):
    assert settings(tmp_path).data_dir == tmp_path


class TestCloudinaryConformance(AdapterConformance):
    adapter_cls = CloudinaryAdapter
    settings = settings(image_generation="on", image_to_video="on")

    def upload_request(self, model):
        content_type = "video/mp4" if model.kind in ("video.reframe", "video.publish") else "image/png"
        return UploadRequest(model=model.id, contentType=content_type, byteCount=100, filename="a")

    def job_request(self, model, asset_ref):
        params, role = {
            "image.removeBackground": ({}, None),
            "image.edit": ({"op": "remove", "prompt": "the cup"}, None),
            "image.upscale": ({}, None),
            "video.reframe": ({"aspectRatio": "9:16"}, None),
            "video.publish": ({}, None),
            "image.generate": ({"prompt": "a lighthouse"}, "reference"),
            "video.generate": ({"prompt": "waves", "duration": 4}, "startFrame"),
        }[model.kind]
        return JobRequest(kind=model.kind, model=model.id, params=params,
                          inputs=[AssetInput(assetRef=asset_ref, role=role)])

    def _common(self, router, derived=(), video_gone_after_submit=False):
        body = {"asset_id": "a1", "width": 100, "height": 100, "bytes": 100, "duration": 3.0, "format": "mp4",
                "derived": [{"transformation": t, "format": t.rpartition("/")[2]} for t in derived]}
        seen = set()

        def resource(request):
            if video_gone_after_submit and "/video/" in request.url.path and request.url.path in seen:
                return httpx.Response(404)
            seen.add(request.url.path)
            if request.url.params.get("media_metadata") != "true":
                return httpx.Response(200, json={k: v for k, v in body.items() if k != "duration"})
            return httpx.Response(200, json=body)
        router.get(url__regex=r"https://api\.cloudinary\.com/v1_1/demo/resources/.*").mock(side_effect=resource)
        router.post(f"{API}/v1_1/demo/video/explicit").respond(200, json={})
        router.post(url__startswith=GEN).respond(202, json={"data": {"status": "pending", "task_id": "t1"}})
        router.post(I2V).respond(201, json={"data": {"job_id": "v1", "status": "pending"}})

    def mock_running(self, router):
        self._common(router)
        router.get(url__startswith=DELIVERY).respond(423)
        router.get(url__startswith=f"{GEN}/tasks/").respond(200, json=gen_task("processing"))
        router.get(url__startswith=f"{I2V}/").respond(200, json=i2v_job("pending"))

    def mock_succeeded(self, router):
        self._common(router, derived=("sp_auto:maxres_1080p/m3u8", "so_auto/jpg"))
        router.get(url__startswith=DELIVERY).respond(206)
        router.get(url__startswith=f"{GEN}/tasks/").respond(200, json=gen_task("completed"))
        router.get(url__startswith=f"{I2V}/").respond(200, json=i2v_job("completed"))

    def mock_failed(self, router):
        self._common(router, video_gone_after_submit=True)
        router.get(url__startswith=DELIVERY).respond(404, headers={"X-Cld-Error": "Resource not found"})
        router.get(url__startswith=f"{GEN}/tasks/").respond(200, json=gen_task("failed"))
        router.get(url__startswith=f"{I2V}/").respond(200, json=i2v_job("failed"))

    def mock_unreachable(self, router):
        self._common(router)
        router.get(url__startswith=DELIVERY).mock(side_effect=httpx.ConnectError("down"))
        router.get(url__startswith=f"{GEN}/tasks/").mock(side_effect=httpx.ConnectError("down"))
        router.get(url__startswith=f"{I2V}/").mock(side_effect=httpx.ConnectError("down"))


def test_full_capabilities_fixture_matches_the_adapter(tmp_path):
    fixture = json.loads((Path(__file__).resolve().parents[4] / "protocol/fixtures/Capabilities.cloudinaryFull.json").read_text())
    models = run(lambda a: asyncio.sleep(0, a.models()), settings(tmp_path, image_generation="on", image_to_video="on"))
    assert fixture["models"] == [m.model_dump(mode="json") for m in models]
