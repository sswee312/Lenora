import pytest

from lenora_adapter_cloudinary.addons import IMAGE_GENERATION, IMAGE_TO_VIDEO, Addons
from lenora_adapter_cloudinary.store import CHAIN_RETENTION_SECONDS, Store

NOW = 1_790_000_000.0


def addons(tmp_path, **modes) -> Addons:
    return Addons({IMAGE_GENERATION: modes.get("gen", "auto"), IMAGE_TO_VIDEO: modes.get("i2v", "auto")},
                  Store(tmp_path / "s.sqlite3", now=NOW))


@pytest.mark.parametrize("mode, available", [("auto", True), ("on", True), ("off", False)])
def test_initial_availability(mode, available, tmp_path):
    assert addons(tmp_path, gen=mode).available(IMAGE_GENERATION) is available


def test_auto_learns_and_survives_reopen(tmp_path):
    error = addons(tmp_path).learn_refusal(IMAGE_GENERATION, "403", NOW)
    assert error.code == "provider_unavailable" and not error.retryable and "Test Connection" in error.detail
    reopened = addons(tmp_path)
    assert not reopened.available(IMAGE_GENERATION) and reopened.available(IMAGE_TO_VIDEO)


def test_on_mode_ignores_refusals(tmp_path):
    a = addons(tmp_path, gen="on")
    a.learn_refusal(IMAGE_GENERATION, "403", NOW)
    assert a.available(IMAGE_GENERATION)


def test_recheck_forgets_and_details_explain(tmp_path):
    a = addons(tmp_path, i2v="off")
    a.learn_refusal(IMAGE_GENERATION, "403", NOW)
    rows = {r["id"]: r for r in a.details()}
    assert rows[IMAGE_GENERATION]["available"] is False and "403" in rows[IMAGE_GENERATION]["reason"]
    assert rows[IMAGE_TO_VIDEO] == {"id": IMAGE_TO_VIDEO, "mode": "off", "available": False, "reason": "turned off in settings"}
    a.recheck()
    assert a.available(IMAGE_GENERATION)


def test_chains_round_trip_advance_once_and_expire(tmp_path):
    store = Store(tmp_path / "s.sqlite3", now=NOW)
    store.insert_chain("c1", "t1", {"prompt": "x"}, NOW)
    store.advance_chain("c1", "v1")
    store.advance_chain("c1", "v2")
    chain = store.chain("c1")
    assert (chain.stage, chain.i2v_id, chain.params) == ("video", "v1", {"prompt": "x"})
    assert Store(tmp_path / "s.sqlite3", now=NOW + CHAIN_RETENTION_SECONDS + 1).chain("c1") is None
