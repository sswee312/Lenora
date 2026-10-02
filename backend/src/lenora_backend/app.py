from collections.abc import Callable
from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI

from lenora_backend import __version__
from lenora_backend.auth import require_token
from lenora_backend.errors import install_error_handlers
from lenora_backend.idempotency import IdempotencyStore
from lenora_backend.registry import Registry
from lenora_backend.routes import capabilities, health, jobs, uploads
from lenora_backend.settings import CoreSettings

HTTP_TIMEOUT = httpx.Timeout(connect=5.0, read=30.0, write=30.0, pool=5.0)


def create_app(settings: CoreSettings, load_registry: Callable[[httpx.AsyncClient], Registry] = Registry.load) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, follow_redirects=False) as http:
            app.state.registry = load_registry(http)
            yield

    docs = "/docs" if settings.docs_enabled else None
    app = FastAPI(title="lenora-backend", version=__version__, lifespan=lifespan,
                  docs_url=docs, redoc_url=None, openapi_url="/openapi.json" if docs else None)
    app.state.settings = settings
    install_error_handlers(app)
    protected = [Depends(require_token)]
    app.include_router(health.router, prefix="/v1")
    app.include_router(capabilities.router, prefix="/v1", dependencies=protected)
    app.state.idempotency = IdempotencyStore()
    app.include_router(uploads.router, prefix="/v1", dependencies=protected)
    app.include_router(jobs.router, prefix="/v1", dependencies=protected)
    return app
