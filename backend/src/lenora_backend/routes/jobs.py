from fastapi import APIRouter, Header, Request
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from lenora_backend.errors import ProblemError, provider_call
from lenora_backend.kinds import PARAMS, TERMINAL, JobRequest, JobState, input_problem

router = APIRouter()
DEFAULT_RETRY_AFTER = 2


def _state_response(adapter_id: str, state: JobState) -> JSONResponse:
    body = state.model_copy(update={"jobId": f"{adapter_id}:{state.jobId}"}).model_dump(mode="json")
    headers = {} if state.status in TERMINAL else {"Retry-After": str(state.retryAfter or DEFAULT_RETRY_AFTER)}
    return JSONResponse(body, headers=headers)


@router.post("/jobs", status_code=202)
async def submit_job(
    body: JobRequest, request: Request,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
) -> JSONResponse:
    if not idempotency_key or len(idempotency_key) > 255:
        raise ProblemError("invalid_request", "Idempotency-Key header (1–255 characters) is required.")
    adapter, model = request.app.state.registry.model(body.model)
    if body.kind != model.kind or body.kind not in PARAMS:
        raise ProblemError("unsupported_kind", f"{body.model} does not perform {body.kind}.")
    try:
        PARAMS[body.kind].model_validate(body.params)
    except ValidationError as error:
        fields = "; ".join(f"{'.'.join(str(p) for p in e['loc'])}: {e['msg']}" for e in error.errors())
        raise ProblemError("invalid_request", f"Invalid params for {body.kind}: {fields}") from None
    if problem := input_problem(body.kind, body.inputs):
        raise ProblemError("invalid_request", problem)

    timeout = request.app.state.settings.provider_timeout_seconds

    async def submit():
        job = await provider_call(adapter.submit(body.model, body), timeout)
        return job.model_copy(update={"jobId": f"{adapter.id}:{job.jobId}", "estimate": job.estimate or model.estimate})

    job = await request.app.state.idempotency.run(idempotency_key, body.model_dump_json(), submit)
    return JSONResponse(job.model_dump(mode="json"), status_code=202)


@router.get("/jobs/{job_id:path}")
async def get_job(job_id: str, request: Request) -> JSONResponse:
    adapter, local = request.app.state.registry.job_adapter(job_id)
    timeout = request.app.state.settings.provider_timeout_seconds
    return _state_response(adapter.id, await provider_call(adapter.status(local), timeout))


@router.delete("/jobs/{job_id:path}")
async def cancel_job(job_id: str, request: Request) -> JSONResponse:
    adapter, local = request.app.state.registry.job_adapter(job_id)
    timeout = request.app.state.settings.provider_timeout_seconds
    return _state_response(adapter.id, await provider_call(adapter.cancel(local), timeout))
