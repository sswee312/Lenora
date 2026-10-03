from fakes import AUTH, FakeAdapter
from lenora_backend.registry import AdapterStatus


def test_public_health_hides_details(make_client):
    body = make_client(FakeAdapter()).get("/v1/health").json()
    assert body == {"status": "ok", "protocolVersion": "1"}


def test_wrong_token_gets_public_health(make_client):
    body = make_client(FakeAdapter()).get("/v1/health", headers={"Authorization": "Bearer nope"}).json()
    assert set(body) == {"status", "protocolVersion"}


def test_authorized_health_lists_adapters(make_client):
    statuses = [
        AdapterStatus(id="fake", enabled=True, reason=None, version="0.0.1"),
        AdapterStatus(id="off", enabled=False, reason="missing or invalid: LENORA_OFF_KEY", version="0.0.1"),
    ]
    body = make_client(FakeAdapter(), statuses=statuses).get("/v1/health", headers=AUTH).json()
    assert body["backendVersion"] == "0.1.0"
    assert body["adapters"] == [
        {"id": "fake", "enabled": True, "reason": None, "details": None},
        {"id": "off", "enabled": False, "reason": "missing or invalid: LENORA_OFF_KEY", "details": None},
    ]


class DetailedAdapter(FakeAdapter):
    rechecks: list[bool]

    async def health(self, recheck: bool):
        self.rechecks = [*getattr(self, "rechecks", []), recheck]
        return {"addons": []}


def test_health_details_and_recheck_reach_the_adapter(make_client):
    adapter = DetailedAdapter()
    client = make_client(adapter)
    assert client.get("/v1/health", headers=AUTH).json()["adapters"][0]["details"] == {"addons": []}
    client.get("/v1/health?recheck=addons", headers=AUTH)
    client.get("/v1/health?recheck=addons")
    assert adapter.rechecks == [False, True]


def test_models_are_read_per_request(make_client):
    adapter = FakeAdapter()
    client = make_client(adapter)
    assert len(client.get("/v1/capabilities", headers=AUTH).json()["models"]) == 1
    adapter.models = lambda: []
    assert client.get("/v1/capabilities", headers=AUTH).json()["models"] == []


def test_capabilities_requires_token(make_client):
    response = make_client(FakeAdapter()).get("/v1/capabilities")
    assert response.status_code == 401
    assert response.headers["content-type"] == "application/problem+json"
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json()["code"] == "unauthorized"


def test_non_bearer_scheme_is_rejected(make_client):
    response = make_client(FakeAdapter()).get("/v1/capabilities", headers={"Authorization": "Basic " + "t" * 43})
    assert response.status_code == 401


def test_docs_disabled_in_production(make_client):
    client = make_client(FakeAdapter(), env="production")
    assert client.get("/docs").status_code == 404
