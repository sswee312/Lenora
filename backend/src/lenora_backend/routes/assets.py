from fastapi import APIRouter, Query, Request, Response

from lenora_backend.errors import ProblemError, provider_call

router = APIRouter()


@router.delete("/assets/{asset_ref:path}", status_code=204)
async def delete_asset(asset_ref: str, request: Request, model: str = Query(min_length=1)) -> Response:
    adapter, info = request.app.state.registry.model(model)
    delete = getattr(adapter, "delete_asset", None)
    if not info.deletable or delete is None:
        raise ProblemError("invalid_request", f"{model} does not delete assets.")
    await provider_call(delete(model, asset_ref), request.app.state.settings.provider_timeout_seconds)
    return Response(status_code=204)
