import asyncio
import logging

import pytest

from fakes import AUTH, FakeAdapter
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import InputLimits, ModelInfo


class PublishingAdapter(FakeAdapter):
    def __init__(self, settings=None, http=None):
        super().__init__(settings, http)
        self.deleted: list[str] = []
        self.started = False

    def models(self):
        return [*super().models(), ModelInfo(
            id="fake/publish", kind="video.publish", displayName="Fake Publish",
            inputs=InputLimits(types=["video/mp4"], maxBytes=1000), cancellable=False, deletable=True)]

    async def start(self):
        self.started = True

    async def delete_asset(self, model, asset_ref):
        if asset_ref == "fake/gone":
            raise ProblemError("not_found", "Unknown asset.")
        self.deleted.append(asset_ref)


def test_delete_asset_returns_204(make_client):
    adapter = PublishingAdapter()
    response = make_client(adapter).delete("/v1/assets/fake/asset", params={"model": "fake/publish"}, headers=AUTH)
    assert response.status_code == 204 and adapter.deleted == ["fake/asset"]


def test_deleting_a_missing_asset_is_not_found(make_client):
    response = make_client(PublishingAdapter()).delete("/v1/assets/fake/gone", params={"model": "fake/publish"}, headers=AUTH)
    assert (response.status_code, response.json()["code"]) == (404, "not_found")


@pytest.mark.parametrize("params", [{"model": "fake/cutout"}, {}])
def test_delete_needs_a_deletable_model(params, make_client):
    response = make_client(PublishingAdapter()).delete("/v1/assets/fake/asset", params=params, headers=AUTH)
    assert (response.status_code, response.json()["code"]) == (400, "invalid_request")


def test_delete_requires_the_token(make_client):
    assert make_client(PublishingAdapter()).delete("/v1/assets/fake/asset", params={"model": "fake/publish"}).status_code == 401


def test_adapters_start_before_serving(make_client):
    adapter = PublishingAdapter()
    make_client(adapter)
    assert adapter.started


def test_a_failing_start_does_not_stop_the_backend(make_client):
    class Broken(PublishingAdapter):
        async def start(self):
            raise RuntimeError("usage lookup failed")
    assert make_client(Broken()).get("/v1/capabilities", headers=AUTH).status_code == 200


def test_delete_on_an_adapter_without_delete_asset_is_invalid_request(make_client):
    class NoDelete(PublishingAdapter):
        delete_asset = None
    response = make_client(NoDelete()).delete("/v1/assets/fake/asset", params={"model": "fake/publish"}, headers=AUTH)
    assert (response.status_code, response.json()["code"]) == (400, "invalid_request")


def test_a_failing_start_logs_only_the_adapter_and_exception_type(make_client, caplog):
    class Broken(PublishingAdapter):
        async def start(self):
            raise RuntimeError("provider said sk-secret")
    with caplog.at_level(logging.WARNING, logger="lenora.registry"):
        make_client(Broken())
    text = caplog.text
    assert "fake" in text and "RuntimeError" in text and "sk-secret" not in text


def test_a_hanging_start_times_out_and_startup_continues(make_client, caplog):
    class Hangs(PublishingAdapter):
        async def start(self):
            await asyncio.Event().wait()
    with caplog.at_level(logging.WARNING, logger="lenora.registry"):
        client = make_client(Hangs(), provider_timeout_seconds=0.05)
    assert client.get("/v1/capabilities", headers=AUTH).status_code == 200
    assert "TimeoutError" in caplog.text


@pytest.mark.parametrize("start, reason", [
    (RuntimeError("x"), "start failed: RuntimeError"), (None, "start timed out")])
def test_an_adapter_that_fails_to_start_is_disabled_with_a_reason(start, reason, make_client):
    class Broken(PublishingAdapter):
        async def start(self):
            if start is None:
                await asyncio.Event().wait()
            raise start
    client = make_client(Broken(), provider_timeout_seconds=0.05)
    assert client.get("/v1/capabilities", headers=AUTH).json()["adapters"] == []
    health = client.get("/v1/health", headers=AUTH).json()
    assert [(a["enabled"], a["reason"]) for a in health["adapters"]] == [(False, reason)]
