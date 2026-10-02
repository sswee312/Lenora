import asyncio

import pytest

from lenora_backend.errors import ProblemError
from lenora_backend.idempotency import IdempotencyStore
from lenora_backend.kinds import SubmittedJob


def run(coro):
    return asyncio.run(coro)


def test_same_key_returns_same_job_and_submits_once():
    store, calls = IdempotencyStore(), []

    async def submit():
        calls.append(1)
        return SubmittedJob(jobId=f"j{len(calls)}", status="queued")

    async def scenario():
        return await store.run("k", "fp", submit), await store.run("k", "fp", submit)

    first, second = run(scenario())
    assert first == second and len(calls) == 1


def test_key_reused_with_different_request_is_rejected():
    store = IdempotencyStore()

    async def submit():
        return SubmittedJob(jobId="j", status="queued")

    async def scenario():
        await store.run("k", "fp1", submit)
        await store.run("k", "fp2", submit)

    with pytest.raises(ProblemError) as info:
        run(scenario())
    assert info.value.code == "invalid_request"


def test_failed_submit_is_not_remembered():
    store, attempts = IdempotencyStore(), []

    async def submit():
        attempts.append(1)
        if len(attempts) == 1:
            raise ProblemError("provider_unavailable", "down")
        return SubmittedJob(jobId="j", status="queued")

    async def scenario():
        with pytest.raises(ProblemError):
            await store.run("k", "fp", submit)
        return await store.run("k", "fp", submit)

    assert run(scenario()).jobId == "j"


def test_entries_expire():
    now = [0.0]
    store = IdempotencyStore(ttl_seconds=10, clock=lambda: now[0])
    jobs = iter(["a", "b"])

    async def submit():
        return SubmittedJob(jobId=next(jobs), status="queued")

    async def scenario():
        first = await store.run("k", "fp", submit)
        now[0] = 11
        return first, await store.run("k", "fp", submit)

    first, second = run(scenario())
    assert (first.jobId, second.jobId) == ("a", "b")
