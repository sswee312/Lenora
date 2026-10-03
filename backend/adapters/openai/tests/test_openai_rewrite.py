import asyncio
import json
from pathlib import Path

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from fakes import AUTH, build_app
from oai import MODEL, REWRITTEN, RESPONSES, answer, completed, error, rewrite, run, settings
from lenora_backend.errors import ProblemError
from lenora_adapter_openai import OpenAIAdapter
from lenora_adapter_openai.adapter import REWRITE_REASONING, REWRITE_USD_PER_CALL, output_text

FIXTURES = Path(__file__).resolve().parents[4] / "protocol/fixtures"


def rewrite_body(tmp_path, request) -> dict:
    route = {}

    def mock(router):
        route["responses"] = answer(router, "a red car")
    run(lambda a: a.submit("openai/rewrite", request), settings(tmp_path), mock)
    return json.loads(route["responses"].calls.last.request.content)


def test_models_match_the_protocol_fixture(tmp_path):
    fixture = json.loads((FIXTURES / "Capabilities.openai.json").read_text())["models"]
    models = run(lambda a: asyncio.sleep(0, a.models()), settings(tmp_path))
    assert [m.model_dump(exclude_none=True) for m in models] == fixture


def test_rewrite_request_shape(tmp_path):
    body = rewrite_body(tmp_path, rewrite("a cat", "video.generate", guidance="moodier"))
    assert (body["model"], body["input"], body["store"], body["max_output_tokens"]) == ("gpt-5.4-mini", "a cat", False, 2000)
    assert body.get("reasoning") == REWRITE_REASONING
    assert "video generator" in body["instructions"] and body["instructions"].endswith("The user also asks: moodier")


@pytest.mark.parametrize("target, phrase", [
    ("video.generate", "At most 1000 characters"),
    ("image.generate", "At most 1000 characters"),
    ("audio.speech", "Never add stage directions"),
    ("image.edit", "At most 100 characters"),
])
def test_each_target_gets_its_own_instructions(tmp_path, target, phrase):
    body = rewrite_body(tmp_path, rewrite("a cat", target))
    assert phrase in body["instructions"] and "Return only the improved prompt" in body["instructions"]
    assert "The user also asks" not in body["instructions"]


def test_rewrite_returns_its_text_on_the_first_poll(tmp_path):
    async def scenario(a):
        job = await a.submit("openai/rewrite", rewrite())
        return job, await a.status(job.jobId), a.budget.usage()["used"]
    job, state, used = run(scenario, settings(tmp_path), answer)
    assert job.status == "succeeded" and job.jobId.startswith("rewrite:")
    assert (state.status, state.text, state.results) == ("succeeded", REWRITTEN, None)
    assert (job.estimate.amount, job.estimate.unit) == (REWRITE_USD_PER_CALL, "usd")
    assert used == pytest.approx(REWRITE_USD_PER_CALL)


@pytest.mark.parametrize("body, text", [
    (completed("  Two parts. "), "Two parts."),
    ({"status": "completed", "output": [{"type": "message", "content": [
        {"type": "output_text", "text": "One, "}, {"type": "refusal", "refusal": "no"}, {"type": "output_text", "text": "two."}]}]},
     "One, two."),
    (completed(status="incomplete"), None),
    (completed("   "), None),
    ({"status": "completed", "output": [{"type": "reasoning", "summary": []}]}, None),
    ({"status": "completed", "output": None}, None),
    ([], None),
], ids=["strip", "joins-text-parts", "incomplete", "blank", "no-message", "no-output", "not-an-object"])
def test_output_text(body, text):
    assert output_text(body) == text


@pytest.mark.parametrize("mock, target, code, used", [
    (lambda r: r.post(RESPONSES).mock(return_value=error(429)), "image.generate", "rate_limited", 0),
    (lambda r: r.post(RESPONSES).mock(return_value=error(500)), "image.generate", "provider_error", 0),
    (lambda r: r.post(RESPONSES).mock(side_effect=httpx.ConnectError("down")), "image.generate", "provider_unavailable", 0),
    (lambda r: r.post(RESPONSES).mock(side_effect=httpx.ReadTimeout("slow")), "image.generate", "provider_unavailable",
     REWRITE_USD_PER_CALL),
    (lambda r: answer(r, status="incomplete"), "image.generate", "provider_error", REWRITE_USD_PER_CALL),
    (lambda r: answer(r, "x" * 1001), "video.generate", "provider_error", REWRITE_USD_PER_CALL),
    (lambda r: answer(r, "a cat: on a roof!"), "image.edit", "provider_error", REWRITE_USD_PER_CALL),
    (lambda r: r.post(RESPONSES).respond(200, content=b"not json"), "image.generate", "provider_error", REWRITE_USD_PER_CALL),
], ids=["429", "500", "unsent", "read-timeout", "incomplete", "too-long", "edit-charset", "unreadable"])
def test_rewrite_refusals_refund_and_bad_outputs_keep(tmp_path, mock, target, code, used):
    async def scenario(a):
        with pytest.raises(ProblemError) as info:
            await a.submit("openai/rewrite", rewrite(target=target))
        return info.value.code, a.budget.usage()["used"]
    assert run(scenario, settings(tmp_path), mock) == (code, pytest.approx(used))


def test_a_rewrite_that_fits_image_edit_is_accepted(tmp_path):
    async def scenario(a):
        return (await a.status((await a.submit("openai/rewrite", rewrite("the red car", "image.edit"))).jobId)).text
    assert run(scenario, settings(tmp_path), lambda r: answer(r, "red vintage car")) == "red vintage car"


def test_rewrite_rate_limit_passes_retry_after_on(tmp_path):
    async def scenario(a):
        with pytest.raises(ProblemError) as info:
            await a.submit("openai/rewrite", rewrite())
        return info.value.headers
    limited = lambda r: r.post(RESPONSES).mock(return_value=error(429, headers={"retry-after": "7"}))
    assert run(scenario, settings(tmp_path), limited) == {"Retry-After": "7"}


def test_rewrites_are_not_cancellable(tmp_path):
    async def scenario(a):
        job = await a.submit("openai/rewrite", rewrite())
        with pytest.raises(ProblemError) as info:
            await a.cancel(job.jobId)
        return info.value.code
    assert run(scenario, settings(tmp_path), answer) == "not_cancellable"


def test_a_rewrite_id_does_not_resolve_as_speech(tmp_path):
    async def scenario(a):
        job = await a.submit("openai/rewrite", rewrite())
        with pytest.raises(ProblemError) as info:
            await a.status(job.jobId.replace("rewrite:", "speech:", 1))
        return info.value.code
    assert run(scenario, settings(tmp_path), answer) == "not_found"


def test_rewrite_through_the_core_returns_text_and_no_results(tmp_path):
    body = {"kind": "text.rewritePrompt", "model": "openai/rewrite", "params": {"text": "a cat", "targetKind": "image.generate"}}
    with respx.mock(assert_all_called=False) as router:
        router.get(MODEL).respond(200, json={})
        answer(router)
        with TestClient(build_app(OpenAIAdapter(settings(tmp_path), httpx.AsyncClient()), data_dir=tmp_path)) as client:
            job_id = client.post("/v1/jobs", json=body, headers={**AUTH, "Idempotency-Key": "r"}).json()["jobId"]
            state = client.get(f"/v1/jobs/{job_id}", headers=AUTH).json()
    assert (state["jobId"], state["status"], state["text"], state["results"]) == (job_id, "succeeded", REWRITTEN, None)
