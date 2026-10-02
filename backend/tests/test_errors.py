import pytest

from fakes import AUTH, FakeAdapter
from lenora_backend.errors import STATUS, ProblemError


@pytest.mark.parametrize("code", sorted(STATUS))
def test_every_code_has_status_and_retryable(code):
    err = ProblemError(code, "x")
    assert err.status == STATUS[code]
    assert err.retryable == (code in {"rate_limited", "provider_unavailable"})


def test_unknown_route_is_problem_json(make_client):
    response = make_client(FakeAdapter()).get("/v1/nope", headers=AUTH)
    assert response.status_code == 404
    assert response.headers["content-type"] == "application/problem+json"
    assert response.json()["code"] == "not_found"

