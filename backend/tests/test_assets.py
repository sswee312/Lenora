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
