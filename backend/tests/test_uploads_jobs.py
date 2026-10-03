import pytest

from fakes import AUTH, FakeAdapter

UPLOAD = {"model": "fake/cutout", "contentType": "image/png", "byteCount": 10, "filename": "a.png"}
JOB = {"kind": "image.removeBackground", "model": "fake/cutout", "inputs": [{"assetRef": "fake/asset"}], "params": {}}


def headers(key="key-1"):
    return {**AUTH, "Idempotency-Key": key}


def test_upload_returns_ticket(make_client):
    body = make_client(FakeAdapter()).post("/v1/uploads", headers=AUTH, json=UPLOAD).json()
    assert body["assetRef"] == "fake/asset"
    assert body["ticket"]["method"] == "PUT"


def test_upload_rejects_too_large(make_client):
    response = make_client(FakeAdapter()).post("/v1/uploads", headers=AUTH, json={**UPLOAD, "byteCount": 1001})
    assert (response.status_code, response.json()["code"]) == (413, "input_too_large")


@pytest.mark.parametrize("content_type", ["image/gif", "video/mp4", "image/vnd.adobe.photoshop"])
def test_upload_rejects_unsupported_type(content_type, make_client):
    response = make_client(FakeAdapter()).post("/v1/uploads", headers=AUTH, json={**UPLOAD, "contentType": content_type})
    assert (response.status_code, response.json()["code"]) == (400, "invalid_request")


@pytest.mark.parametrize("byte_count", [0, -1])
def test_upload_rejects_non_positive_size(byte_count, make_client):
    response = make_client(FakeAdapter()).post("/v1/uploads", headers=AUTH, json={**UPLOAD, "byteCount": byte_count})
    assert response.json()["code"] == "invalid_request"


def test_upload_unknown_model(make_client):
    response = make_client(FakeAdapter()).post("/v1/uploads", headers=AUTH, json={**UPLOAD, "model": "x/y"})
    assert response.json()["code"] == "unknown_model"


def test_submit_prefixes_job_id_and_returns_202(make_client):
    response = make_client(FakeAdapter()).post("/v1/jobs", headers=headers(), json=JOB)
    assert response.status_code == 202
    assert response.json()["jobId"] == "fake:job1"


def test_submit_requires_idempotency_key(make_client):
    response = make_client(FakeAdapter()).post("/v1/jobs", headers=AUTH, json=JOB)
    assert (response.status_code, response.json()["code"]) == (400, "invalid_request")


def test_submit_is_idempotent(make_client):
    adapter = FakeAdapter()
    client = make_client(adapter)
    first = client.post("/v1/jobs", headers=headers(), json=JOB).json()
    second = client.post("/v1/jobs", headers=headers(), json=JOB).json()
    assert first == second and len(adapter.submitted) == 1


def test_submit_kind_must_match_model(make_client):
    response = make_client(FakeAdapter()).post("/v1/jobs", headers=headers(), json={**JOB, "kind": "image.upscale"})
    assert response.json()["code"] == "unsupported_kind"


def test_submit_rejects_unknown_params(make_client):
    response = make_client(FakeAdapter()).post("/v1/jobs", headers=headers(), json={**JOB, "params": {"x": 1}})
    assert response.json()["code"] == "invalid_request"


def test_submit_rejects_wrong_input_count(make_client):
    two = {**JOB, "inputs": [{"assetRef": "a"}, {"assetRef": "b"}]}
    assert make_client(FakeAdapter()).post("/v1/jobs", headers=headers(), json=two).json()["code"] == "invalid_request"


def test_poll_sets_retry_after_until_terminal(make_client):
    adapter = FakeAdapter()
    client = make_client(adapter)
    job_id = client.post("/v1/jobs", headers=headers(), json=JOB).json()["jobId"]
    running = client.get(f"/v1/jobs/{job_id}", headers=AUTH)
    assert (running.json()["status"], running.headers["retry-after"]) == ("running", "3")
    adapter.finish("job1")
    done = client.get(f"/v1/jobs/{job_id}", headers=AUTH)
    assert done.json()["jobId"] == "fake:job1"
    assert done.json()["results"][0]["fileExtension"] == "png"
    assert "retry-after" not in done.headers
    assert "retryAfter" not in done.json()


def test_poll_unknown_job(make_client):
    assert make_client(FakeAdapter()).get("/v1/jobs/fake:nope", headers=AUTH).json()["code"] == "not_found"


def test_cancel_not_cancellable(make_client):
    response = make_client(FakeAdapter()).delete("/v1/jobs/fake:job1", headers=AUTH)
    assert (response.status_code, response.json()["code"]) == (409, "not_cancellable")


def test_job_routes_require_token(make_client):
    client = make_client(FakeAdapter())
    assert client.post("/v1/jobs", json=JOB, headers={"Idempotency-Key": "k"}).status_code == 401
    assert client.get("/v1/jobs/fake:job1").status_code == 401


def test_submit_unknown_kind_is_unsupported(make_client):
    response = make_client(FakeAdapter()).post("/v1/jobs", headers=headers(), json={**JOB, "kind": "audio.dub"})
    assert (response.status_code, response.json()["code"]) == (422, "unsupported_kind")


class CrashingAdapter(FakeAdapter):
    async def status(self, job_id):
        raise RuntimeError("adapter bug with a secret-ish detail")


def test_unexpected_adapter_error_is_problem_json(make_client):
    response = make_client(CrashingAdapter()).get("/v1/jobs/fake:job1", headers=AUTH)
    assert response.headers["content-type"] == "application/problem+json"
    assert (response.json()["code"], response.json()["retryable"]) == ("provider_error", False)
    assert "secret-ish" not in response.text
