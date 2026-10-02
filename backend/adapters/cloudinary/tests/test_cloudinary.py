import asyncio
import base64

import httpx
import pytest
import respx

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput, JobRequest, UploadRequest, UrlInput
from lenora_backend.testing.conformance import AdapterConformance
from lenora_adapter_cloudinary import CloudinaryAdapter, CloudinarySettings, sign

SETTINGS = CloudinarySettings(cloud_name="demo", api_key="123456789012345", api_secret="abcd")
DELIVERY = "https://res.cloudinary.com/demo/image/upload/e_background_removal/"


def run(coro_fn):
    async def go():
        async with httpx.AsyncClient() as http:
            return await coro_fn(CloudinaryAdapter(SETTINGS, http))
    return asyncio.run(go())


def test_signature_matches_cloudinary_documented_example():
    # Example from https://cloudinary.com/documentation/authentication_signatures
    params = {"eager": "w_400,h_300,c_pad|w_260,h_200,c_crop", "public_id": "sample_image", "timestamp": "1315060510"}
    assert sign(params, "abcd") == "bfd09f95f331f558cbd1320e67aa8d488770583e"


def test_ticket_fields_and_asset_ref():
    req = UploadRequest(model="cloudinary/background-removal", contentType="image/png", byteCount=10, filename="a.png")
    ticket = run(lambda a: a.create_upload(req.model, req))
    fields = ticket.ticket.fields
    assert str(ticket.ticket.url) == "https://api.cloudinary.com/v1_1/demo/image/upload"
    assert ticket.ticket.fileField == "file"
    assert set(fields) == {"api_key", "timestamp", "public_id", "signature"}
    assert fields["public_id"].startswith("lenora/")
    assert ticket.assetRef == f"image/upload/{fields['public_id']}"
    assert fields["signature"] == sign({"public_id": fields["public_id"], "timestamp": fields["timestamp"]}, "abcd")
    assert "abcd" not in ticket.model_dump_json()


def test_submit_builds_delivery_url():
    ref = "image/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d"
    job = JobRequest(kind="image.removeBackground", model="cloudinary/background-removal", inputs=[AssetInput(assetRef=ref)])
    submitted = run(lambda a: a.submit(job.model, job))
    encoded = submitted.jobId.removeprefix("url:")
    url = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()
    assert url == DELIVERY + "lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d.png"


@pytest.mark.parametrize("ref", [
    "image/upload/other/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d",
    "image/upload/lenora/../../x",
    "video/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d",
])
def test_submit_rejects_foreign_asset_refs(ref):
    job = JobRequest(kind="image.removeBackground", model="cloudinary/background-removal", inputs=[AssetInput(assetRef=ref)])
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.submit(job.model, job))
    assert info.value.code == "invalid_request"


def test_submit_rejects_url_inputs():
    job = JobRequest(kind="image.removeBackground", model="cloudinary/background-removal",
                     inputs=[UrlInput(url="https://example.com/a.png")])
    with pytest.raises(ProblemError):
        run(lambda a: a.submit(job.model, job))


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


def test_status_sends_range_header():
    ref = "image/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d"
    job = JobRequest(kind="image.removeBackground", model="cloudinary/background-removal", inputs=[AssetInput(assetRef=ref)])
    with respx.mock as router:
        route = router.get(url__startswith=DELIVERY).respond(206)

        async def scenario(a):
            return await a.status((await a.submit(job.model, job)).jobId)
        assert run(scenario).status == "succeeded"
        assert route.calls.last.request.headers["range"] == "bytes=0-0"


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


class TestCloudinaryConformance(AdapterConformance):
    adapter_cls = CloudinaryAdapter
    settings = SETTINGS

    def upload_request(self, model):
        return UploadRequest(model=model.id, contentType="image/png", byteCount=100, filename="a.png")

    def job_request(self, model, asset_ref):
        return JobRequest(kind=model.kind, model=model.id, inputs=[AssetInput(assetRef=asset_ref)])

    def mock_running(self, router):
        router.get(url__startswith=DELIVERY).respond(423)

    def mock_succeeded(self, router):
        router.get(url__startswith=DELIVERY).respond(206, headers={"Content-Type": "image/png"})

    def mock_failed(self, router):
        router.get(url__startswith=DELIVERY).respond(404, headers={"X-Cld-Error": "Resource not found"})

    def mock_unreachable(self, router):
        router.get(url__startswith=DELIVERY).mock(side_effect=httpx.ConnectError("down"))
