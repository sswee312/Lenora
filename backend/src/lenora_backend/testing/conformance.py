"""Conformance suite every adapter reuses. Subclass AdapterConformance in the adapter's tests."""
import asyncio
from typing import ClassVar, Literal

import httpx
import pytest
import respx
from pydantic_settings import BaseSettings

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import INPUT_ROLES, PARAMS, TERMINAL, JobRequest, JobState, ModelInfo, SubmittedJob, UploadRequest

STATUSES = {"queued", "running", "succeeded", "failed", "cancelled"}
FAILURE_CODES = {"provider_error", "quota_exceeded", "rate_limited", "input_too_large"}


class AdapterConformance:
    adapter_cls: ClassVar[type]
    settings: ClassVar[BaseSettings]
    # Kinds whose provider call the adapter makes itself: "submit" finishes inside submit and fails from it;
    # "background" runs in a task that submit starts. Other kinds run at the provider and are polled there.
    adapter_run: ClassVar[dict[str, Literal["submit", "background"]]] = {}

    def upload_request(self, model: ModelInfo) -> UploadRequest: raise NotImplementedError
    def job_request(self, model: ModelInfo, asset_ref: str | None) -> JobRequest: raise NotImplementedError
    def mock_running(self, router: respx.Router) -> None: raise NotImplementedError
    def mock_succeeded(self, router: respx.Router) -> None: raise NotImplementedError
    def mock_failed(self, router: respx.Router) -> None: raise NotImplementedError
    def mock_unreachable(self, router: respx.Router) -> None: raise NotImplementedError

    async def settle(self, adapter) -> None:
        """Wait for background work that submit started. Adapters without "background" kinds need nothing."""

    def _run(self, scenario, mock=None):
        async def go():
            with respx.mock(assert_all_called=False) as router:
                if mock:
                    mock(router)
                async with httpx.AsyncClient() as http:
                    adapter = self.adapter_cls(self.settings, http)
                    try:
                        return await scenario(adapter)
                    finally:
                        if stop := getattr(adapter, "stop", None):
                            await stop()
        return asyncio.run(go())

    def _models(self, adapter) -> list[ModelInfo]:
        models = [m for m in adapter.models() if m.kind in PARAMS]
        assert models, "adapter claims no kinds the core can validate"
        return models

    async def _submit(self, adapter, model: ModelInfo) -> SubmittedJob:
        asset_ref = None
        if model.inputs.types:
            asset_ref = (await adapter.create_upload(model.id, self.upload_request(model))).assetRef
        job = await adapter.submit(model.id, self.job_request(model, asset_ref))
        assert job.status in STATUSES and job.jobId
        run = self.adapter_run.get(model.kind)
        if run == "submit":
            assert job.status == "succeeded"
        elif run == "background":
            assert job.status == "queued"
        return job

    def test_identity_and_models(self):
        assert self.adapter_cls.id.isidentifier() and self.adapter_cls.id == self.adapter_cls.id.lower()

        async def scenario(adapter):
            for model in self._models(adapter):
                ModelInfo.model_validate(model.model_dump())
                assert model.id.startswith(f"{adapter.id}/")
                assert model.inputs.maxBytes > 0
                assert model.inputs.types or not INPUT_ROLES[model.kind], f"{model.id} takes inputs but accepts no types"
        self._run(scenario)

    def test_upload_ticket_shape(self):
        async def scenario(adapter):
            for model in self._models(adapter):
                if not model.inputs.types:
                    with pytest.raises(ProblemError) as info:
                        await adapter.create_upload(model.id, self.upload_request(model))
                    assert info.value.code == "invalid_request"
                    continue
                ticket = await adapter.create_upload(model.id, self.upload_request(model))
                assert ticket.assetRef
                assert ticket.ticket.url.scheme == "https"
                if ticket.ticket.method == "POST":
                    assert ticket.ticket.fileField
        self._run(scenario)

    def test_running_then_succeeded_is_terminal(self):
        async def running(adapter):
            states = []
            for model in self._models(adapter):
                job = await self._submit(adapter, model)
                if self.adapter_run.get(model.kind) != "submit":
                    states.append(await adapter.status(job.jobId))
            return states
        for state in self._run(running, self.mock_running):
            assert state.status in {"queued", "running"} and state.results is None

        async def succeeded(adapter):
            job_ids = [(await self._submit(adapter, m)).jobId for m in self._models(adapter)]
            await self.settle(adapter)
            return [(await adapter.status(j), await adapter.status(j)) for j in job_ids]
        for first, second in self._run(succeeded, self.mock_succeeded):
            assert first.status == "succeeded" and (first.results or first.text)
            assert all(r.fileExtension for r in first.results or [])
            assert (second.status, second.results, second.text) == (first.status, first.results, first.text)

    def test_new_instance_polls_old_job_id(self):
        async def scenario(adapter):
            job_ids = [(await self._submit(adapter, m)).jobId for m in self._models(adapter)]
            await self.settle(adapter)
            async with httpx.AsyncClient() as http:
                fresh = self.adapter_cls(self.settings, http)
                return [await fresh.status(j) for j in job_ids]
        for state in self._run(scenario, self.mock_succeeded):
            assert state.status == "succeeded"

    def test_provider_failure_maps_to_failed_state(self):
        async def scenario(adapter):
            outcomes: list[JobState | ProblemError] = []
            for model in self._models(adapter):
                if self.adapter_run.get(model.kind) == "submit":
                    with pytest.raises(ProblemError) as info:
                        await self._submit(adapter, model)
                    outcomes.append(info.value)
                    continue
                job = await self._submit(adapter, model)
                await self.settle(adapter)
                outcomes.append(await adapter.status(job.jobId))
            return outcomes
        for outcome in self._run(scenario, self.mock_failed):
            if isinstance(outcome, ProblemError):
                assert outcome.code in FAILURE_CODES
            else:
                assert outcome.status == "failed" and outcome.error is not None
                assert outcome.error.code in FAILURE_CODES

    def test_unreachable_provider_is_not_terminal(self):
        """Provider-run jobs survive an unreachable provider. An adapter-run call that never connected is lost:
        it fails retryable with provider_unavailable (from submit, or as the background job's state)."""
        async def scenario(adapter):
            outcomes: list[tuple[str | None, JobState | ProblemError | httpx.TransportError]] = []
            for model in self._models(adapter):
                run = self.adapter_run.get(model.kind)
                try:
                    job = await self._submit(adapter, model)
                    await self.settle(adapter)
                    outcomes.append((run, await adapter.status(job.jobId)))
                except (httpx.TransportError, ProblemError) as error:
                    outcomes.append((run, error))
            return outcomes
        for run, outcome in self._run(scenario, self.mock_unreachable):
            if run == "background":
                assert isinstance(outcome, JobState) and outcome.status == "failed"
                assert outcome.error.code == "provider_unavailable" and outcome.error.retryable
            elif run == "submit":
                assert isinstance(outcome, ProblemError)
                assert outcome.code == "provider_unavailable" and outcome.retryable
            elif isinstance(outcome, JobState):
                assert outcome.status not in TERMINAL
            elif isinstance(outcome, ProblemError):
                assert outcome.code == "provider_unavailable" and outcome.retryable
