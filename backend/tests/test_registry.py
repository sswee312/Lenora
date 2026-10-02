import pytest
from pydantic import Field, ValidationError
from pydantic_settings import BaseSettings, SettingsConfigDict

from fakes import AUTH, FakeAdapter
from lenora_backend.errors import ProblemError
from lenora_backend.registry import AdapterStatus, Registry, missing_settings_reason


class NeedsKey(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LENORA_DEMO_")
    api_key: str = Field(min_length=1)


def test_missing_settings_reason_names_env_vars_not_values():
    with pytest.raises(ValidationError) as info:
        NeedsKey()
    assert missing_settings_reason("demo", info.value) == "missing or invalid: LENORA_DEMO_API_KEY"


def test_job_adapter_routes_on_prefix():
    adapter = FakeAdapter()
    registry = Registry({"fake": adapter}, [])
    assert registry.job_adapter("fake:url:abc") == (adapter, "url:abc")


@pytest.mark.parametrize("job_id", ["", "fake", "fake:", "other:job1", ":job1"])
def test_job_adapter_rejects_unknown(job_id):
    with pytest.raises(ProblemError) as info:
        Registry({"fake": FakeAdapter()}, []).job_adapter(job_id)
    assert info.value.code == "not_found"


def test_unknown_model():
    with pytest.raises(ProblemError) as info:
        Registry({"fake": FakeAdapter()}, []).model("fake/missing")
    assert info.value.code == "unknown_model"


def test_capabilities_lists_only_enabled_adapters(make_client):
    statuses = [
        AdapterStatus("fake", True, None, "0.0.1"),
        AdapterStatus("off", False, "missing or invalid: LENORA_OFF_KEY", "0.0.1"),
    ]
    body = make_client(FakeAdapter(), statuses=statuses).get("/v1/capabilities", headers=AUTH).json()
    assert body["protocolVersion"] == "1"
    assert body["adapters"] == [{"id": "fake", "version": "0.0.1"}]
    assert [m["id"] for m in body["models"]] == ["fake/cutout"]
