"""Conformance suite every adapter reuses. Subclass AdapterConformance in the adapter's tests."""
import asyncio
from typing import ClassVar

import httpx
import pytest
import respx
from pydantic_settings import BaseSettings

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import PARAMS, TERMINAL, JobRequest, JobState, ModelInfo, UploadRequest

STATUSES = {"queued", "running", "succeeded", "failed", "cancelled"}


class AdapterConformance:
    adapter_cls: ClassVar[type]
    settings: ClassVar[BaseSettings]

    def upload_request(self, model: ModelInfo) -> UploadRequest: raise NotImplementedError
    def job_request(self, model: ModelInfo, asset_ref: str) -> JobRequest: raise NotImplementedError
    def mock_running(self, router: respx.Router) -> None: raise NotImplementedError
    def mock_succeeded(self, router: respx.Router) -> None: raise NotImplementedError
    def mock_failed(self, router: respx.Router) -> None: raise NotImplementedError
    def mock_unreachable(self, router: respx.Router) -> None: raise NotImplementedError

    def _run(self, scenario, mock=None):
        async def go():
            with respx.mock(assert_all_called=False) as router:
                if mock:
                    mock(router)
                async with httpx.AsyncClient() as http:
                    return await scenario(self.adapter_cls(self.settings, http))
        return asyncio.run(go())

    def _models(self, adapter) -> list[ModelInfo]:
        models = [m for m in adapter.models() if m.kind in PARAMS]
        assert models, "adapter claims no kinds the core can validate"
        return models

    async def _submit(self, adapter, model: ModelInfo) -> str:
        ticket = await adapter.create_upload(model.id, self.upload_request(model))
        job = await adapter.submit(model.id, self.job_request(model, ticket.assetRef))
        assert job.status in STATUSES and job.jobId
        return job.jobId

    def test_identity_and_models(self):
        assert self.adapter_cls.id.isidentifier() and self.adapter_cls.id == self.adapter_cls.id.lower()

        async def scenario(adapter):
            for model in self._models(adapter):
                ModelInfo.model_validate(model.model_dump())
                assert model.id.startswith(f"{adapter.id}/")
                assert model.inputs.types and model.inputs.maxBytes > 0
        self._run(scenario)

    def test_upload_ticket_shape(self):
        async def scenario(adapter):
            for model in self._models(adapter):
                ticket = await adapter.create_upload(model.id, self.upload_request(model))
                assert ticket.assetRef
                assert ticket.ticket.url.scheme == "https"
                if ticket.ticket.method == "POST":
                    assert ticket.ticket.fileField
        self._run(scenario)

    def test_running_then_succeeded_is_terminal(self):
        async def running(adapter):
            return [await adapter.status(await self._submit(adapter, m)) for m in self._models(adapter)]
        for state in self._run(running, self.mock_running):
            assert state.status in {"queued", "running"} and state.results is None

        async def succeeded(adapter):
            states = []
            for model in self._models(adapter):
                job_id = await self._submit(adapter, model)
                first, second = await adapter.status(job_id), await adapter.status(job_id)
                states.append((first, second))
            return states
        for first, second in self._run(succeeded, self.mock_succeeded):
            assert first.status == "succeeded" and first.results
            assert all(r.fileExtension for r in first.results)
            assert second.status == first.status and second.results == first.results

    def test_new_instance_polls_old_job_id(self):
        async def scenario(adapter):
            job_ids = [await self._submit(adapter, m) for m in self._models(adapter)]
            async with httpx.AsyncClient() as http:
                fresh = self.adapter_cls(self.settings, http)
                return [await fresh.status(j) for j in job_ids]
        for state in self._run(scenario, self.mock_succeeded):
            assert state.status == "succeeded"

    def test_provider_failure_maps_to_failed_state(self):
        async def scenario(adapter):
            return [await adapter.status(await self._submit(adapter, m)) for m in self._models(adapter)]
        for state in self._run(scenario, self.mock_failed):
            assert state.status == "failed" and state.error is not None
            assert state.error.code in {"provider_error", "quota_exceeded", "rate_limited", "input_too_large"}

    def test_unreachable_provider_is_not_terminal(self):
        async def scenario(adapter):
            job_ids = [await self._submit(adapter, m) for m in self._models(adapter)]
            outcomes = []
            for job_id in job_ids:
                try:
                    outcomes.append(await adapter.status(job_id))
                except (httpx.TransportError, ProblemError) as error:
                    outcomes.append(error)
            return outcomes
        for outcome in self._run(scenario, self.mock_unreachable):
            if isinstance(outcome, JobState):
                assert outcome.status not in TERMINAL
            elif isinstance(outcome, ProblemError):
                assert outcome.code == "provider_unavailable" and outcome.retryable
