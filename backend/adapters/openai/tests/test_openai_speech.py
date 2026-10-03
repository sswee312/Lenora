import asyncio
import json
import logging
import stat

import httpx
import pytest
import respx
from fastapi.testclient import TestClient
from pydantic import ValidationError

from fakes import AUTH, build_app
from oai import AUDIO, DAY, KEY, MODEL, SPEECH, Gate, error, finished, mp3, run, settings, speech
from lenora_backend.errors import ProblemError
from lenora_backend.jobids import sign_job
from lenora_backend.kinds import UploadRequest
from lenora_backend.registry import missing_settings_reason
from lenora_backend.results import MARKER_HOST, TTL_SECONDS, ResultStore
from lenora_backend.testing.conformance import AdapterConformance
from lenora_adapter_openai import OpenAIAdapter, OpenAISettings, speech_jobs
from lenora_adapter_openai import adapter as adapter_module
from lenora_adapter_openai import api as api_module
from lenora_adapter_openai.adapter import SPEECH_USD_PER_1000_CHARS, load_signing_key, speech_estimate

ONE = SPEECH_USD_PER_1000_CHARS


class TestOpenAIConformance(AdapterConformance):
    adapter_cls = OpenAIAdapter
    settings = settings()
    adapter_run = {"audio.speech": "background"}

    def upload_request(self, model):
        return UploadRequest(model=model.id, contentType="audio/mpeg", byteCount=1, filename="a.mp3")

    def job_request(self, model, asset_ref):
        return speech()

    def mock_running(self, router):
        router.post(SPEECH).mock(side_effect=Gate())

    def mock_succeeded(self, router):
        mp3(router)

    def mock_failed(self, router):
        router.post(SPEECH).mock(return_value=error(500))

    def mock_unreachable(self, router):
        router.post(SPEECH).mock(side_effect=httpx.ConnectError("down"))

    async def settle(self, adapter):
        await adapter.speech_jobs.join()


def outcome(tmp_path, mock, request=None, **overrides):
    """Run one voiceover job to its end; returns the final state and the budget used afterwards."""
    async def scenario(a):
        return await finished(a, request), a.budget.usage()["used"]
    return run(scenario, settings(tmp_path, **overrides), mock)


def submit_problem(tmp_path, mock, request=None):
    """Submit one voiceover expecting a refusal at submit; returns the problem and the budget used afterwards."""
    async def scenario(a):
        with pytest.raises(ProblemError) as info:
            await a.submit("openai/voice", request or speech())
        return info.value, a.budget.usage()["used"]
    return run(scenario, settings(tmp_path), mock)


def test_submit_returns_queued_before_openai_answers(tmp_path):
    async def scenario(a):
        job = await a.submit("openai/voice", speech())
        return job, await a.status(job.jobId), a.budget.usage()["used"]
    job, state, used = run(scenario, settings(tmp_path), lambda r: r.post(SPEECH).mock(side_effect=Gate()))
    assert job.status == "queued" and job.jobId.startswith("speech:")
    assert state.status in ("queued", "running") and state.results is None and state.error is None
    assert (job.estimate.amount, job.estimate.unit) == (ONE, "usd") and used == pytest.approx(ONE)


@pytest.mark.parametrize("fmt, content_type", [("mp3", "audio/mpeg"), ("wav", "audio/wav")])
def test_voiceover_succeeds_once_its_job_ends(tmp_path, fmt, content_type):
    async def scenario(a):
        state = await finished(a, speech(format=fmt))
        stored = await a.results.open(state.results[0].url.path.lstrip("/"))
        return state, stored.path.read_bytes()
    state, data = run(scenario, settings(tmp_path), mp3)
    result = state.results[0]
    assert state.status == "succeeded" and state.error is None
    assert (result.url.host, result.contentType, result.fileExtension, data) == (MARKER_HOST, content_type, fmt, AUDIO)


def test_speech_request_carries_script_voice_style_format_and_timeout(tmp_path):
    route = {}

    def mock(router):
        route["speech"] = mp3(router)
    run(lambda a: finished(a, speech("Hello there.", voice="nova", styleInstructions="Warm.", format="wav")),
        settings(tmp_path), mock)
    request = route["speech"].calls.last.request
    assert json.loads(request.content) == {"model": "gpt-4o-mini-tts", "input": "Hello there.", "voice": "nova",
                                           "response_format": "wav", "instructions": "Warm."}
    assert request.headers["authorization"] == f"Bearer {KEY}"
    assert request.extensions["timeout"] == {"connect": 5.0, "read": 60.0, "write": 30.0, "pool": 5.0}


def test_omitted_voice_uses_the_default_and_sends_no_instructions(tmp_path):
    route = {}

    def mock(router):
        route["speech"] = mp3(router)
    run(lambda a: finished(a, speech(styleInstructions="")), settings(tmp_path), mock)
    assert json.loads(route["speech"].calls.last.request.content) == {
        "model": "gpt-4o-mini-tts", "input": "Welcome back.", "voice": "alloy", "response_format": "mp3"}


def test_unknown_voice_is_refused_before_openai(tmp_path):
    route = {}

    def mock(router):
        route["speech"] = mp3(router)
    problem, used = submit_problem(tmp_path, mock, speech(voice="robot"))
    assert problem.code == "invalid_request" and "robot" in problem.detail and "alloy" in problem.detail
    assert used == 0 and not route["speech"].called


@pytest.mark.parametrize("response, code, retryable", [
    (error(401), "provider_unavailable", False),
    (error(403), "provider_unavailable", False),
    (error(429, code="insufficient_quota", type_="insufficient_quota"), "quota_exceeded", False),
    (error(429), "rate_limited", True),
    (error(400, message="Invalid value: 'robot'."), "invalid_request", False),
    (error(422), "invalid_request", False),
    (error(404), "provider_error", False),
    (error(500), "provider_error", True),
    (error(503), "provider_error", True),
], ids=["401", "403", "429-quota", "429", "400", "422", "404", "500", "503"])
def test_openai_refusals_fail_the_job_and_refund(tmp_path, response, code, retryable):
    state, used = outcome(tmp_path, lambda r: r.post(SPEECH).mock(return_value=response))
    assert (state.status, state.error.code, state.error.retryable, used) == ("failed", code, retryable, 0)


def test_rate_limit_passes_retry_after_on():
    assert api_module.refusal(error(429, headers={"retry-after": "7"})).headers == {"Retry-After": "7"}


def test_safe_invalid_request_messages_are_passed_on(tmp_path):
    state, _ = outcome(tmp_path, lambda r: r.post(SPEECH).mock(return_value=error(400, message="Invalid value: 'robot'.")))
    assert state.error.message == "OpenAI rejected the request: Invalid value: 'robot'."


def test_messages_with_key_material_are_replaced(tmp_path):
    leaky = error(400, message=f"Incorrect API key provided: {KEY[:12]}****cdef.")
    state, _ = outcome(tmp_path, lambda r: r.post(SPEECH).mock(return_value=leaky))
    assert state.error.message == "OpenAI rejected the request." and KEY[:8] not in state.error.message


def test_error_bodies_never_reach_logs_or_problems(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    state, _ = outcome(tmp_path, lambda r: r.post(SPEECH).mock(return_value=error(500, message="secret-body-marker")))
    assert "secret-body-marker" not in state.error.message and "secret-body-marker" not in caplog.text
    assert KEY not in caplog.text and "Welcome back." not in caplog.text
    assert "failed in request: provider_error" in caplog.text


@pytest.mark.parametrize("failure", [httpx.ConnectError("down"), httpx.ConnectTimeout("slow"), httpx.PoolTimeout("busy")],
                         ids=["connect", "connect-timeout", "pool"])
def test_unsent_requests_are_refunded(tmp_path, failure):
    state, used = outcome(tmp_path, lambda r: r.post(SPEECH).mock(side_effect=failure))
    assert (state.status, state.error.code, state.error.retryable, used) == ("failed", "provider_unavailable", True, 0)


@pytest.mark.parametrize("failure", [httpx.ReadTimeout("slow"), httpx.RemoteProtocolError("cut")], ids=["read-timeout", "cut"])
def test_failures_after_sending_keep_the_reservation(tmp_path, failure):
    state, used = outcome(tmp_path, lambda r: r.post(SPEECH).mock(side_effect=failure))
    assert (state.status, state.error.code, state.error.retryable) == ("failed", "provider_unavailable", True)
    assert used == pytest.approx(ONE)


def test_the_total_cap_fails_the_job_and_keeps_the_reservation(tmp_path, monkeypatch):
    monkeypatch.setattr(api_module, "SPEECH_TOTAL_SECONDS", 0)
    state, used = outcome(tmp_path, lambda r: r.post(SPEECH).mock(side_effect=Gate()))
    assert (state.status, state.error.code, state.error.retryable) == ("failed", "provider_unavailable", True)
    assert "in time" in state.error.message and used == pytest.approx(ONE)


def test_at_most_four_voiceovers_run_at_once(tmp_path):
    gate = Gate()

    async def scenario(a):
        jobs = [await a.submit("openai/voice", speech()) for _ in range(speech_jobs.MAX_RUNNING + 1)]
        await gate.arrivals(speech_jobs.MAX_RUNNING)
        during = [(await a.status(j.jobId)).status for j in jobs]
        held = gate.waiting
        gate.release()
        await a.speech_jobs.join()
        return during, held, [(await a.status(j.jobId)).status for j in jobs]
    during, held, after = run(scenario, settings(tmp_path), lambda r: r.post(SPEECH).mock(side_effect=gate))
    assert during == ["running"] * speech_jobs.MAX_RUNNING + ["queued"] and held == speech_jobs.MAX_RUNNING
    assert after == ["succeeded"] * (speech_jobs.MAX_RUNNING + 1)


def test_too_many_pending_voiceovers_are_refused_before_reserving(tmp_path, monkeypatch):
    monkeypatch.setattr(speech_jobs, "MAX_PENDING", 1)

    async def scenario(a):
        await a.submit("openai/voice", speech())
        with pytest.raises(ProblemError) as info:
            await a.submit("openai/voice", speech())
        return info.value, a.budget.usage()["used"]
    problem, used = run(scenario, settings(tmp_path), lambda r: r.post(SPEECH).mock(side_effect=Gate()))
    assert (problem.code, problem.retryable, problem.headers) == ("rate_limited", True, {"Retry-After": "10"})
    assert used == pytest.approx(ONE)


def test_cancel_while_queued_refunds(tmp_path, monkeypatch):
    monkeypatch.setattr(speech_jobs, "MAX_RUNNING", 1)
    gate, route = Gate(), {}

    def mock(router):
        route["speech"] = router.post(SPEECH).mock(side_effect=gate)

    async def scenario(a):
        first = await a.submit("openai/voice", speech())
        await gate.arrivals(1)
        second = await a.submit("openai/voice", speech())
        queued = (await a.status(second.jobId)).status
        cancelled = (await a.cancel(second.jobId)).status
        used = a.budget.usage()["used"]
        gate.release()
        await a.speech_jobs.join()
        return queued, cancelled, used, (await a.status(first.jobId)).status, (await a.status(second.jobId)).status
    assert run(scenario, settings(tmp_path), mock) == ("queued", "cancelled", pytest.approx(ONE), "succeeded", "cancelled")
    assert route["speech"].call_count == 1


def test_cancel_while_running_keeps_the_reservation_and_leaves_no_file(tmp_path):
    gate = Gate()

    async def scenario(a):
        job = await a.submit("openai/voice", speech())
        await gate.arrivals(1)
        running = (await a.status(job.jobId)).status
        cancelled = (await a.cancel(job.jobId)).status
        again = (await a.cancel(job.jobId)).status
        return running, cancelled, again, gate.waiting, a.budget.usage()["used"]
    assert run(scenario, settings(tmp_path), lambda r: r.post(SPEECH).mock(side_effect=gate)) == (
        "running", "cancelled", "cancelled", 0, pytest.approx(ONE))
    assert list((tmp_path / "results").glob("*")) == []


def hold_writes(a, failure: Exception | None = None) -> tuple[asyncio.Event, asyncio.Event]:
    """Hold every result write once it starts until `proceed` is set; then write, or raise `failure`."""
    entered, proceed = asyncio.Event(), asyncio.Event()
    put = a.results.put_bytes

    async def held_put(*args, **kwargs):
        entered.set()
        await proceed.wait()
        if failure is not None:
            raise failure
        return await put(*args, **kwargs)
    a.results.put_bytes = held_put
    return entered, proceed


def test_cancel_during_the_write_leaves_no_file(tmp_path):
    async def scenario(a):
        entered, proceed = hold_writes(a)
        job = await a.submit("openai/voice", speech())
        await entered.wait()
        cancelling = asyncio.create_task(a.cancel(job.jobId))
        proceed.set()
        return (await cancelling).status, (await a.status(job.jobId)).status
    assert run(scenario, settings(tmp_path), mp3) == ("cancelled", "cancelled")
    assert list((tmp_path / "results").glob("*")) == []


def test_stop_during_the_write_leaves_no_file(tmp_path):
    async def scenario(a):
        entered, proceed = hold_writes(a)
        job = await a.submit("openai/voice", speech())
        await entered.wait()
        stopping = asyncio.create_task(a.stop())
        proceed.set()
        await stopping
        return job.jobId, (await a.status(job.jobId)).status
    job_id, status = run(scenario, settings(tmp_path), mp3)
    assert status == "running" and list((tmp_path / "results").glob("*")) == []
    assert run(lambda a: a.status(job_id), settings(tmp_path)).status == "failed"


def test_a_cancelled_result_that_cannot_be_removed_reports_failed(tmp_path, monkeypatch, caplog):
    monkeypatch.setattr(speech_jobs, "MAX_FINISHED", 0)

    async def scenario(a):
        entered, proceed = hold_writes(a)

        async def broken_delete(result_id):
            raise PermissionError("read-only")
        a.results.delete = broken_delete
        job = await a.submit("openai/voice", speech())
        await entered.wait()
        cancelling = asyncio.create_task(a.cancel(job.jobId))
        proceed.set()
        cancelled = await cancelling
        await a.submit("openai/voice", speech())  # admission prunes finished entries
        return cancelled, await a.status(job.jobId)
    cancelled, later = run(scenario, settings(tmp_path), mp3)
    assert (cancelled.status, cancelled.error.code, cancelled.error.retryable) == ("failed", "provider_error", False)
    assert later == cancelled
    assert "could not remove its cancelled result: PermissionError" in caplog.text


def test_a_failed_write_after_cancel_is_logged(tmp_path, caplog):
    async def scenario(a):
        entered, proceed = hold_writes(a, OSError("disk full"))
        job = await a.submit("openai/voice", speech())
        await entered.wait()
        cancelling = asyncio.create_task(a.cancel(job.jobId))
        proceed.set()
        return (await cancelling).status
    assert run(scenario, settings(tmp_path), mp3) == "cancelled"
    assert "could not write its cancelled result: OSError" in caplog.text


def test_unexpected_failures_are_logged_with_a_traceback(tmp_path, caplog):
    async def scenario(a):
        async def broken_put(*args, **kwargs):
            raise RuntimeError("local disk detail")
        a.results.put_bytes = broken_put
        return await finished(a)
    state = run(scenario, settings(tmp_path), mp3)
    assert (state.status, state.error.code, state.error.message) == (
        "failed", "provider_error", "The voiceover failed unexpectedly.")
    record = next(r for r in caplog.records if "failed in store" in r.getMessage())
    assert record.exc_info and record.exc_info[0] is RuntimeError


def test_cancel_after_the_end_returns_the_final_state(tmp_path):
    async def scenario(a):
        state = await finished(a)
        return (await a.cancel(state.jobId)).status
    assert run(scenario, settings(tmp_path), mp3) == "succeeded"


def test_restart_while_running_reports_failed_and_keeps_the_reservation(tmp_path):
    gate, settings_ = Gate(), settings(tmp_path)

    async def scenario(a):
        job = await a.submit("openai/voice", speech())
        await gate.arrivals(1)
        async with httpx.AsyncClient() as http:
            state = await OpenAIAdapter(settings_, http).status(job.jobId)
        return state, a.budget.usage()["used"]
    state, used = run(scenario, settings_, lambda r: r.post(SPEECH).mock(side_effect=gate))
    assert (state.status, state.error.code, state.error.retryable) == ("failed", "provider_unavailable", True)
    assert "restarted" in state.error.message and used == pytest.approx(ONE)


def test_a_signed_job_with_no_record_reports_failed(tmp_path):
    job_id = sign_job("speech", ResultStore.new_id(), load_signing_key(tmp_path / "openai.key"))
    state = run(lambda a: a.status(job_id), settings(tmp_path))
    assert (state.status, state.error.code, state.error.retryable) == ("failed", "provider_unavailable", True)


def test_a_stored_result_is_found_after_a_restart(tmp_path):
    state = run(finished, settings(tmp_path), mp3)
    again = run(lambda a: a.status(state.jobId), settings(tmp_path))
    assert (again.status, again.results) == ("succeeded", state.results)


def test_an_expired_voiceover_reports_failed(tmp_path):
    now = [DAY]

    async def scenario(a):
        state = await finished(a)
        now[0] += TTL_SECONDS + 1
        return await a.status(state.jobId)
    state = run(scenario, settings(tmp_path), mp3, clock=lambda: now[0])
    assert (state.status, state.error.code) == ("failed", "provider_unavailable")


def test_old_finished_entries_are_pruned(tmp_path, monkeypatch):
    monkeypatch.setattr(speech_jobs, "MAX_FINISHED", 1)

    async def scenario(a):
        first, second = await finished(a), await finished(a)
        await a.submit("openai/voice", speech())
        return (await a.status(first.jobId)).error.message, (await a.status(second.jobId)).error.message
    first, second = run(scenario, settings(tmp_path), lambda r: r.post(SPEECH).mock(return_value=error(500)))
    assert "not available" in first and second == "OpenAI failed (HTTP 500)."


def test_stop_cancels_running_jobs_and_commits_nothing(tmp_path):
    gate = Gate()

    async def scenario(a):
        running = await a.submit("openai/voice", speech())
        await gate.arrivals(1)
        await a.stop()
        with pytest.raises(ProblemError) as info:
            await a.submit("openai/voice", speech())
        return gate.waiting, (await a.status(running.jobId)).status, info.value.code, a.budget.usage()["used"]
    held, status, refused, used = run(scenario, settings(tmp_path), lambda r: r.post(SPEECH).mock(side_effect=gate))
    assert (held, refused, used) == (0, "provider_unavailable", pytest.approx(ONE))
    assert status == "running"  # the table is left exactly as stop() found it
    assert list((tmp_path / "results").glob("*")) == []


def test_audio_over_the_size_cap_is_a_provider_error(tmp_path, monkeypatch):
    monkeypatch.setattr(adapter_module, "MAX_BYTES", 4)
    state, used = outcome(tmp_path, mp3)
    assert (state.status, state.error.code, state.error.retryable) == ("failed", "provider_error", False)
    assert used == pytest.approx(ONE)
    assert not list((tmp_path / "results").glob("*.data"))


def test_empty_audio_is_a_provider_error(tmp_path):
    state, _ = outcome(tmp_path, lambda r: r.post(SPEECH).respond(200, content=b""))
    assert (state.status, state.error.code) == ("failed", "provider_error")


def test_daily_cap_refuses_before_openai(tmp_path):
    route = {}

    def mock(router):
        route["speech"] = mp3(router)

    async def scenario(a):
        await finished(a)
        with pytest.raises(ProblemError) as info:
            await a.submit("openai/voice", speech())
        return info.value
    problem = run(scenario, settings(tmp_path, daily_budget_usd=ONE * 1.5), mock)
    assert problem.code == "quota_exceeded" and "OpenAI" in problem.detail and "USD" in problem.detail
    assert route["speech"].call_count == 1


def test_zero_budget_means_no_cap(tmp_path):
    assert run(lambda a: asyncio.sleep(0, a.budget.limit), settings(tmp_path, daily_budget_usd=0)) is None


@pytest.mark.parametrize("chars, thousands", [(1, 1), (1000, 1), (1001, 2), (4096, 5)])
def test_speech_estimate_counts_started_thousands(chars, thousands):
    assert speech_estimate(chars).amount == pytest.approx(thousands * ONE)


def test_voiceover_through_the_core_reserves_once_and_serves_the_audio(tmp_path):
    body = {"kind": "audio.speech", "model": "openai/voice", "params": {"prompt": "Welcome back."}}
    gate = Gate()
    with respx.mock(assert_all_called=False) as router:
        router.get(MODEL).respond(200, json={"id": "gpt-4o-mini-tts"})
        speech_route = router.post(SPEECH).mock(side_effect=gate)
        http = httpx.AsyncClient()
        adapter = OpenAIAdapter(settings(tmp_path), http)
        with TestClient(build_app(adapter, data_dir=tmp_path)) as client:
            first = client.post("/v1/jobs", json=body, headers={**AUTH, "Idempotency-Key": "k"})
            again = client.post("/v1/jobs", json=body, headers={**AUTH, "Idempotency-Key": "k"})
            pending = client.get(f"/v1/jobs/{first.json()['jobId']}", headers=AUTH)
            client.portal.call(gate.release)
            client.portal.call(adapter.speech_jobs.join)
            state = client.get(f"/v1/jobs/{first.json()['jobId']}", headers=AUTH).json()
            url = state["results"][0]["url"]
            audio = client.get(url, headers=AUTH)
            anonymous = client.get(url)
            client.portal.call(http.aclose)
    assert first.status_code == again.status_code == 202 and first.json() == again.json()
    assert first.json()["status"] == "queued" and first.json()["jobId"].startswith("openai:speech:")
    assert pending.json()["status"] in ("queued", "running") and pending.headers["retry-after"] == "2"
    assert speech_route.call_count == 1
    assert adapter.budget.usage()["used"] == pytest.approx(ONE)
    assert state["status"] == "succeeded" and url.startswith("http://testserver/v1/results/")
    assert (audio.status_code, audio.content, audio.headers["content-type"]) == (200, AUDIO, "audio/mpeg")
    assert anonymous.status_code == 401


def test_cancel_through_the_core(tmp_path):
    body = {"kind": "audio.speech", "model": "openai/voice", "params": {"prompt": "Welcome back."}}
    with respx.mock(assert_all_called=False) as router:
        router.get(MODEL).respond(200, json={})
        router.post(SPEECH).mock(side_effect=Gate())
        http = httpx.AsyncClient()
        adapter = OpenAIAdapter(settings(tmp_path), http)
        with TestClient(build_app(adapter, data_dir=tmp_path)) as client:
            job_id = client.post("/v1/jobs", json=body, headers={**AUTH, "Idempotency-Key": "c"}).json()["jobId"]
            cancelled = client.delete(f"/v1/jobs/{job_id}", headers=AUTH)
            capabilities = client.get("/v1/capabilities", headers=AUTH).json()
            client.portal.call(http.aclose)
    assert (cancelled.status_code, cancelled.json()["status"]) == (200, "cancelled")
    assert "retry-after" not in cancelled.headers
    assert next(m for m in capabilities["models"] if m["id"] == "openai/voice")["cancellable"] is True


def forged(job_id: str) -> list[str]:
    payload, signature = job_id.removeprefix("speech:").split(".")
    flipped = signature[:-1] + ("A" if signature[-1] != "A" else "B")
    return [job_id.removeprefix("speech:"), job_id.replace("speech:", "rewrite:", 1), f"speech:{payload}x.{signature}",
            f"speech:{payload}.{flipped}", f"speech:{payload}", "speech:", "other:abc"]


def test_forged_or_foreign_job_ids_are_not_found(tmp_path):
    async def scenario(a):
        job = await a.submit("openai/voice", speech())
        codes = []
        for job_id in forged(job.jobId):
            for call in (a.status, a.cancel):
                with pytest.raises(ProblemError) as info:
                    await call(job_id)
                codes.append(info.value.code)
        return codes
    assert set(run(scenario, settings(tmp_path), mp3)) == {"not_found"}


def test_a_job_from_another_installation_is_not_found(tmp_path):
    job = run(lambda a: a.submit("openai/voice", speech()), settings(tmp_path / "a"), mp3)
    with pytest.raises(ProblemError) as info:
        run(lambda a: a.status(job.jobId), settings(tmp_path / "b"))
    assert info.value.code == "not_found"


def test_signing_key_is_private_and_not_the_api_key(tmp_path):
    run(lambda a: a.submit("openai/voice", speech()), settings(tmp_path), mp3)
    key_file = tmp_path / "openai.key"
    assert stat.S_IMODE(key_file.stat().st_mode) == 0o600
    assert KEY not in key_file.read_text() and len(key_file.read_text().strip()) >= 32


def test_lenora_key_wins_over_the_openai_fallback(monkeypatch):
    monkeypatch.setenv("LENORA_OPENAI_API_KEY", "sk-lenora")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-openai")
    assert OpenAISettings().api_key.get_secret_value() == "sk-lenora"


@pytest.mark.parametrize("lenora", [None, ""], ids=["unset", "empty"])
def test_openai_api_key_is_the_fallback(monkeypatch, lenora):
    monkeypatch.delenv("LENORA_OPENAI_API_KEY", raising=False)
    if lenora is not None:
        monkeypatch.setenv("LENORA_OPENAI_API_KEY", lenora)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-openai")
    assert OpenAISettings().api_key.get_secret_value() == "sk-openai"


def test_without_a_key_the_adapter_is_disabled_with_its_variable_named(monkeypatch):
    monkeypatch.delenv("LENORA_OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    with pytest.raises(ValidationError) as info:
        OpenAISettings()
    assert missing_settings_reason("openai", info.value) == "missing or invalid: LENORA_OPENAI_API_KEY"


@pytest.mark.parametrize("status, models, available", [
    (200, ["openai/voice"], True), (401, [], False), (403, [], False), (404, [], False),
])
def test_start_probe_controls_the_speech_model(tmp_path, status, models, available):
    async def scenario(a):
        await a.start()
        return [m.id for m in a.models()], await a.health(recheck=False)
    ids, health = run(scenario, settings(tmp_path), lambda r: r.get(MODEL).respond(status, json={}))
    assert ids == models and health["addons"][0]["available"] is available
    assert health["addons"][0]["id"] == "gpt-4o-mini-tts"
    assert health["budget"]["unit"] == "usd" and health["budget"]["limit"] == 5.0


def test_unreachable_probe_keeps_the_models(tmp_path):
    async def scenario(a):
        await a.start()
        return [m.id for m in a.models()]
    assert run(scenario, settings(tmp_path), lambda r: r.get(MODEL).mock(side_effect=httpx.ConnectError("down"))) == ["openai/voice"]


def test_recheck_probes_again(tmp_path):
    async def scenario(a):
        await a.start()
        hidden = [m.id for m in a.models()]
        await a.health(recheck=True)
        return hidden, [m.id for m in a.models()]
    responses = [httpx.Response(401, json={}), httpx.Response(200, json={})]
    hidden, shown = run(scenario, settings(tmp_path), lambda r: r.get(MODEL).mock(side_effect=responses))
    assert (hidden, shown) == ([], ["openai/voice"])
