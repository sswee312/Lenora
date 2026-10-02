from fastapi import APIRouter, Request

from lenora_backend.kinds import AdapterVersion, Capabilities

router = APIRouter()


@router.get("/capabilities", response_model=Capabilities)
async def capabilities(request: Request) -> Capabilities:
    registry = request.app.state.registry
    return Capabilities(
        adapters=[AdapterVersion(id=s.id, version=s.version) for s in registry.statuses if s.enabled],
        models=registry.models(),
    )
