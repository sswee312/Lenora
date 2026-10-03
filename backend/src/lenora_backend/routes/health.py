from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from lenora_backend import __version__
from lenora_backend.auth import is_authorized
from lenora_backend.kinds import AdapterHealth, Health

router = APIRouter()


@router.get("/health")
async def health(request: Request) -> JSONResponse:
    if not is_authorized(request.headers.get("authorization"), request.app.state.settings.token):
        return JSONResponse({"status": "ok", "protocolVersion": "1"})
    registry = request.app.state.registry
    details = await registry.health_details(recheck=request.query_params.get("recheck") == "addons")
    body = Health(
        backendVersion=__version__,
        adapters=[AdapterHealth(id=s.id, enabled=s.enabled, reason=s.reason, details=details.get(s.id))
                  for s in registry.statuses],
    )
    return JSONResponse(body.model_dump(mode="json"))
