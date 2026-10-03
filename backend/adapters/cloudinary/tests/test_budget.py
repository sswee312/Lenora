import httpx
import pytest
from fastapi.testclient import TestClient

from cld import IMAGE_REF, job, run, settings
from fakes import AUTH, build_app
from lenora_adapter_cloudinary import CloudinaryAdapter
from lenora_backend.errors import ProblemError
from lenora_adapter_cloudinary.costs import reframe, upscale


@pytest.mark.parametrize("seconds, credits", [(0, 0.014), (1.0, 0.014), (2.01, 0.042), (60, 0.84)])
def test_reframe_counts_started_seconds(seconds, credits):
    assert reframe(seconds).amount == pytest.approx(credits)


@pytest.mark.parametrize("pixels, credits", [(249_999, 0.01), (250_000, 0.1), (4_194_304, 0.1)])
def test_upscale_tiers(pixels, credits):
    assert upscale(pixels).amount == pytest.approx(credits)


def test_over_budget_submit_is_refused_before_cloudinary(tmp_path):
    request = job("image.removeBackground", "cloudinary/background-removal")
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.submit(request.model, request), settings(tmp_path, daily_credit_budget=0.05))
    assert info.value.code == "quota_exceeded"


def test_health_reports_budget_use(tmp_path):
    request = job("image.removeBackground", "cloudinary/background-removal")

    async def scenario(a):
        await a.submit(request.model, request)
        return await a.health(recheck=False)
    budget = run(scenario, settings(tmp_path, daily_credit_budget=1.0))["budget"]
    assert budget["limit"] == 1.0 and budget["used"] == pytest.approx(0.075) and budget["unit"] == "cloudinary_credits"


def test_idempotent_replay_reserves_once(tmp_path):
    adapter = CloudinaryAdapter(settings(tmp_path, daily_credit_budget=1.0), httpx.AsyncClient())
    body = {"kind": "image.removeBackground", "model": "cloudinary/background-removal", "inputs": [{"assetRef": IMAGE_REF}]}
    with TestClient(build_app(adapter)) as client:
        first = client.post("/v1/jobs", json=body, headers={**AUTH, "Idempotency-Key": "k"})
        again = client.post("/v1/jobs", json=body, headers={**AUTH, "Idempotency-Key": "k"})
    assert first.status_code == again.status_code == 202 and first.json() == again.json()
    assert adapter.budget.usage()["used"] == pytest.approx(0.075)
