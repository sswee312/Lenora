import asyncio
import logging
from collections.abc import Awaitable
from typing import Literal, TypeVar

import httpx
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

ErrorCode = Literal[
    "unauthorized", "invalid_request", "unsupported_kind", "unknown_model", "input_too_large",
    "rate_limited", "quota_exceeded", "provider_unavailable", "provider_error", "not_found", "not_cancellable",
]
STATUS: dict[str, int] = {
    "unauthorized": 401, "invalid_request": 400, "unsupported_kind": 422, "unknown_model": 422,
    "input_too_large": 413, "rate_limited": 429, "quota_exceeded": 403, "provider_unavailable": 503,
    "provider_error": 502, "not_found": 404, "not_cancellable": 409,
}
RETRYABLE = {"rate_limited", "provider_unavailable"}
# Transport failures that prove the request never left: nothing reached the provider, so nothing was billed.
NOT_SENT = (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout)
T = TypeVar("T")
log = logging.getLogger("lenora.errors")


class ProblemError(Exception):
    def __init__(self, code: ErrorCode, detail: str, *, status: int | None = None,
                 retryable: bool | None = None, headers: dict[str, str] | None = None):
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.status = status or STATUS[code]
        self.retryable = code in RETRYABLE if retryable is None else retryable
        self.headers = headers or {}


class RequestNotSent(ProblemError):
    """The request provably never reached the provider (connect or pool failure), so nothing was billed."""


def problem_response(err: ProblemError) -> JSONResponse:
    return JSONResponse(
        status_code=err.status,
        media_type="application/problem+json",
        headers=err.headers,
        content={
            "type": f"urn:lenora:problem:{err.code}", "title": err.code, "status": err.status,
            "detail": err.detail, "code": err.code, "retryable": err.retryable,
        },
    )


async def provider_call(awaitable: Awaitable[T], timeout: float) -> T:
    """Bound one adapter call; every failure leaves as a ProblemError."""
    try:
        async with asyncio.timeout(timeout):
            return await awaitable
    except TimeoutError:
        raise ProblemError("provider_unavailable", "The provider did not answer in time.") from None
    except httpx.TransportError as exc:
        raise ProblemError("provider_unavailable", f"Could not reach the provider ({type(exc).__name__}).") from None
    except ProblemError:
        raise
    except Exception:
        log.exception("adapter call failed")
        raise ProblemError("provider_error", "The provider adapter failed unexpectedly.", retryable=False) from None


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ProblemError)
    async def _problem(_: Request, exc: ProblemError):
        return problem_response(exc)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError):
        fields = ", ".join(".".join(str(p) for p in e["loc"] if p != "body") + f": {e['msg']}" for e in exc.errors())
        return problem_response(ProblemError("invalid_request", fields or "Invalid request."))

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException):
        code = "not_found" if exc.status_code == 404 else "invalid_request"
        return problem_response(ProblemError(code, str(exc.detail), status=exc.status_code))
