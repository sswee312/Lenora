import asyncio
import json
import os
import time

import pytest

from fakes import AUTH, FakeAdapter
from lenora_backend.errors import ProblemError
from lenora_backend.kinds import JobState
from lenora_backend.results import MARKER_HOST, MAX_BYTES, STRAY_SECONDS, TTL_SECONDS, ResultStore

NOW = 1_790_000_000.0


def put(tmp_path, data=b"ID3audio", content_type="audio/mpeg", ext="mp3") -> str:
    return asyncio.run(ResultStore(tmp_path / "results").put_bytes(data, content_type, ext))


def test_bytes_round_trip(tmp_path):
    results = ResultStore(tmp_path / "results")
    result_id = asyncio.run(results.put_bytes(b"ID3audio", "audio/mpeg", "mp3"))
    stored = asyncio.run(results.open(result_id))
    assert (stored.content_type, stored.file_extension, stored.path.read_bytes()) == ("audio/mpeg", "mp3", b"ID3audio")
    assert sorted(p.name for p in (tmp_path / "results").iterdir()) == [f"{result_id}.data", f"{result_id}.json"]


def test_text_round_trip(tmp_path):
    results = ResultStore(tmp_path / "results")
    result_id = asyncio.run(results.put_text("Ein Kätzchen auf dem Dach."))
    assert asyncio.run(results.read_text(result_id)) == "Ein Kätzchen auf dem Dach."
    assert asyncio.run(results.open(result_id)).content_type == "text/plain; charset=utf-8"


def test_oversized_result_is_refused_and_writes_nothing(tmp_path):
    with pytest.raises(ProblemError) as info:
        put(tmp_path, data=b"x" * (MAX_BYTES + 1))
    assert (info.value.code, info.value.retryable) == ("provider_error", False)
    assert not (tmp_path / "results").exists()


@pytest.mark.parametrize("result_id", [
    "", "../results", "a" * 31, "a" * 33, "A" * 32, "g" * 32, "a" * 32 + "\n", "a" * 16 + "/" + "a" * 15, "0" * 32,
])
def test_malformed_or_unknown_ids_are_not_found(tmp_path, result_id):
    put(tmp_path)
    with pytest.raises(ProblemError) as info:
        asyncio.run(ResultStore(tmp_path / "results").open(result_id))
    assert info.value.code == "not_found"


def test_failed_write_leaves_no_file(tmp_path, monkeypatch):
    def broken(_fd):
        raise OSError("disk full")
    monkeypatch.setattr(os, "fsync", broken)
    with pytest.raises(OSError):
        put(tmp_path)
    assert list((tmp_path / "results").iterdir()) == []


def test_results_expire_after_a_day(tmp_path):
    now = [NOW]
    results = ResultStore(tmp_path / "results", clock=lambda: now[0])
    result_id = asyncio.run(results.put_bytes(b"ID3", "audio/mpeg", "mp3"))
    now[0] += TTL_SECONDS + 1
    with pytest.raises(ProblemError) as info:
        asyncio.run(results.open(result_id))
    assert info.value.code == "not_found"
    assert asyncio.run(results.sweep()) == 1
    assert list((tmp_path / "results").iterdir()) == []


def test_sweep_keeps_live_results_and_fresh_temp_files(tmp_path):
    results = ResultStore(tmp_path / "results")
    live = asyncio.run(results.put_bytes(b"ID3", "audio/mpeg", "mp3"))
    root = tmp_path / "results"
    stale_temp, fresh_temp, orphan = root / ".a.tmp", root / ".b.tmp", root / ("c" * 32 + ".data")
    for path in (stale_temp, fresh_temp, orphan):
        path.write_bytes(b"x")
    old = time.time() - STRAY_SECONDS - 1
    for path in (stale_temp, orphan):
        os.utime(path, (old, old))
    assert asyncio.run(results.sweep()) == 2
    assert sorted(p.name for p in root.iterdir()) == sorted([".b.tmp", f"{live}.data", f"{live}.json"])


def test_sweep_without_a_directory_is_a_noop(tmp_path):
    assert asyncio.run(ResultStore(tmp_path / "missing").sweep()) == 0


def test_result_route_streams_the_stored_bytes(make_client, tmp_path):
    result_id = put(tmp_path)
    response = make_client(FakeAdapter(), data_dir=tmp_path).get(f"/v1/results/{result_id}", headers=AUTH)
    assert (response.status_code, response.content) == (200, b"ID3audio")
    assert response.headers["content-type"] == "audio/mpeg"
    assert response.headers["content-length"] == "8"
    assert response.headers["cache-control"] == "no-store"


def test_result_route_needs_the_token(make_client, tmp_path):
    response = make_client(FakeAdapter(), data_dir=tmp_path).get(f"/v1/results/{put(tmp_path)}")
    assert (response.status_code, response.json()["code"]) == (401, "unauthorized")


@pytest.mark.parametrize("result_id", ["0" * 32, "not-a-result"])
def test_result_route_unknown_is_not_found(make_client, tmp_path, result_id):
    response = make_client(FakeAdapter(), data_dir=tmp_path).get(f"/v1/results/{result_id}", headers=AUTH)
    assert (response.status_code, response.json()["code"]) == (404, "not_found")


def test_startup_sweeps_expired_results(make_client, tmp_path):
    root = tmp_path / "results"
    root.mkdir()
    (root / ("e" * 32 + ".data")).write_bytes(b"x")
    (root / ("e" * 32 + ".json")).write_text(json.dumps({"contentType": "audio/mpeg", "fileExtension": "mp3", "createdAt": 0}))
    make_client(FakeAdapter(), data_dir=tmp_path)
    assert list(root.iterdir()) == []


def test_stored_results_resolve_to_the_backend_origin(make_client, tmp_path):
    adapter = FakeAdapter()
    adapter.states["job1"] = JobState(jobId="job1", status="succeeded",
                                      results=[ResultStore.result("ab" * 16, "audio/mpeg", "mp3")])
    body = make_client(adapter, data_dir=tmp_path).get("/v1/jobs/fake:job1", headers=AUTH).json()
    assert body["results"][0]["url"] == f"http://testserver/v1/results/{'ab' * 16}"
    assert MARKER_HOST not in json.dumps(body)


def test_other_result_urls_pass_through(make_client, tmp_path):
    adapter = FakeAdapter()
    adapter.states["job1"] = JobState(jobId="job1", status="running")
    adapter.finish("job1")
    body = make_client(adapter, data_dir=tmp_path).get("/v1/jobs/fake:job1", headers=AUTH).json()
    assert body["results"][0]["url"] == "https://cdn.example/out.png"
