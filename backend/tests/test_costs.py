import pytest

from lenora_backend.costs import Budget
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import Estimate

DAY = 1_790_000_000.0  # a fixed UTC instant
CREDIT = "cloudinary_credits"


def credits(limit, clock=lambda: DAY) -> Budget:
    return Budget(limit, clock, provider="Cloudinary", unit=CREDIT, label="credits")


def test_reserve_until_the_limit():
    budget = credits(0.2)
    budget.reserve(Estimate(amount=0.12, unit=CREDIT))
    with pytest.raises(ProblemError) as info:
        budget.reserve(Estimate(amount=0.1, unit=CREDIT))
    assert info.value.code == "quota_exceeded" and not info.value.retryable
    assert info.value.detail == "The daily Cloudinary budget is reached: 0.080 of 0.2 credits left today."
    budget.reserve(Estimate(amount=0.08, unit=CREDIT))


def test_refund_returns_the_reservation():
    budget = credits(0.1)
    budget.reserve(Estimate(amount=0.1, unit=CREDIT))
    budget.refund(Estimate(amount=0.1, unit=CREDIT))
    budget.reserve(Estimate(amount=0.1, unit=CREDIT))


def test_resets_at_utc_midnight():
    now = [DAY]
    budget = credits(0.1, clock=lambda: now[0])
    budget.reserve(Estimate(amount=0.1, unit=CREDIT))
    now[0] += 86400
    budget.reserve(Estimate(amount=0.1, unit=CREDIT))
    assert budget.usage()["used"] == pytest.approx(0.1)


def test_unlimited_without_a_limit():
    credits(None).reserve(Estimate(amount=1e6, unit=CREDIT))


def test_usd_budget_names_its_provider_and_unit():
    budget = Budget(0.05, lambda: DAY, provider="OpenAI", unit="usd", label="USD")
    budget.reserve(Estimate(amount=0.04, unit="usd"))
    with pytest.raises(ProblemError) as info:
        budget.reserve(Estimate(amount=0.015, unit="usd"))
    assert info.value.detail == "The daily OpenAI budget is reached: 0.010 of 0.05 USD left today."
    assert budget.usage() == {"limit": 0.05, "used": 0.04, "day": "2026-09-21", "unit": "usd"}
