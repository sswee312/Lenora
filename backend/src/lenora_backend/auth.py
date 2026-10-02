import hmac

from fastapi import Request
from pydantic import SecretStr

from lenora_backend.errors import ProblemError


def is_authorized(header: str | None, token: SecretStr) -> bool:
    scheme, _, value = (header or "").partition(" ")
    return scheme.lower() == "bearer" and hmac.compare_digest(
        value.strip().encode(), token.get_secret_value().encode()
    )


async def require_token(request: Request) -> None:
    if not is_authorized(request.headers.get("authorization"), request.app.state.settings.token):
        raise ProblemError("unauthorized", "Missing or invalid bearer token.", headers={"WWW-Authenticate": "Bearer"})
