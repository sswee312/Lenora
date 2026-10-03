import httpx
import pytest
from fastapi.testclient import TestClient

from cld import IMAGE_REF, job, run, settings
from fakes import AUTH, build_app
from lenora_adapter_cloudinary import CloudinaryAdapter
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import Estimate
from lenora_adapter_cloudinary.costs import Budget, reframe, upscale

DAY = 1_790_000_000.0  # a fixed UTC instant
CREDIT = "cloudinary_credits"


def test_reserve_until_the_limit():
    budget = Budget(0.2, clock=lambda: DAY)
    budget.reserve(Estimate(amount=0.12, unit=CREDIT))
    with pytest.raises(ProblemError) as info:
        budget.reserve(Estimate(amount=0.1, unit=CREDIT))
    assert info.value.code == "quota_exceeded" and "0.080 of 0.2" in info.value.detail
    budget.reserve(Estimate(amount=0.08, unit=CREDIT))


def test_refund_returns_credit():
    budget = Budget(0.1, clock=lambda: DAY)
    budget.reserve(Estimate(amount=0.1, unit=CREDIT))
    budget.refund(Estimate(amount=0.1, unit=CREDIT))
    budget.reserve(Estimate(amount=0.1, unit=CREDIT))


def test_resets_at_utc_midnight():
    now = [DAY]
    budget = Budget(0.1, clock=lambda: now[0])
    budget.reserve(Estimate(amount=0.1, unit=CREDIT))
    now[0] += 86400
    budget.reserve(Estimate(amount=0.1, unit=CREDIT))
    assert budget.usage()["used"] == pytest.approx(0.1)


def test_unlimited_without_a_limit():
    Budget(None, clock=lambda: DAY).reserve(Estimate(amount=1e6, unit=CREDIT))


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
    assert budget["limit"] == 1.0 and budget["used"] == pytest.approx(0.075)


def test_idempotent_replay_reserves_once(tmp_path):
    adapter = CloudinaryAdapter(settings(tmp_path, daily_credit_budget=1.0), httpx.AsyncClient())
    body = {"kind": "image.removeBackground", "model": "cloudinary/background-removal", "inputs": [{"assetRef": IMAGE_REF}]}
    with TestClient(build_app(adapter)) as client:
        first = client.post("/v1/jobs", json=body, headers={**AUTH, "Idempotency-Key": "k"})
        again = client.post("/v1/jobs", json=body, headers={**AUTH, "Idempotency-Key": "k"})
    assert first.status_code == again.status_code == 202 and first.json() == again.json()
    assert adapter.budget.usage()["used"] == pytest.approx(0.075)
