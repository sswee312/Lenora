from fastapi import APIRouter, Request

from lenora_backend.errors import ProblemError, provider_call
from lenora_backend.kinds import UploadRequest, UploadTicket

router = APIRouter()


@router.post("/uploads", response_model=UploadTicket)
async def create_upload(body: UploadRequest, request: Request) -> UploadTicket:
    adapter, model = request.app.state.registry.model(body.model)
    if body.contentType not in model.inputs.types:
        raise ProblemError("invalid_request", f"{body.model} accepts {', '.join(model.inputs.types)}; got {body.contentType}.")
    if body.byteCount > model.inputs.maxBytes:
        raise ProblemError("input_too_large", f"{body.model} accepts files up to {model.inputs.maxBytes} bytes.")
    timeout = request.app.state.settings.provider_timeout_seconds
    return await provider_call(adapter.create_upload(body.model, body), timeout)
