import re
from dataclasses import dataclass

import httpx

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import AssetInput, UrlInput
from lenora_adapter_cloudinary.settings import CloudinarySettings

ASSET_REF = re.compile(
    r"^(image|video)/upload/(lenora/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"
)
DEFAULT_RATE_LIMIT_RETRY = 30


@dataclass(frozen=True)
class AssetRef:
    resource_type: str
    public_id: str


@dataclass(frozen=True)
class Asset:
    asset_id: str
    width: int | None
    height: int | None
    bytes: int
    duration: float | None


def parse_ref(item: AssetInput | UrlInput, resource_type: str) -> AssetRef:
    match = ASSET_REF.match(item.assetRef) if isinstance(item, AssetInput) else None
    if match is None or match.group(1) != resource_type:
        raise ProblemError("invalid_request", f"Inputs must be {resource_type} assetRefs from this backend's upload ticket.")
    return AssetRef(match.group(1), match.group(2))


def error_message(response: httpx.Response) -> str:
    try:
        body = response.json()
    except ValueError:
        body = None
    if isinstance(body, dict):
        error = body.get("error") or (body.get("data") or {}).get("error")
        if isinstance(error, dict) and isinstance(error.get("message"), str):
            return error["message"]
    return response.headers.get("X-Cld-Error") or f"Cloudinary returned HTTP {response.status_code}."


def problem(response: httpx.Response) -> ProblemError:
    """Map a non-success Cloudinary API response to a protocol problem."""
    status, message = response.status_code, error_message(response)
    if status in (420, 429):
        retry = response.headers.get("Retry-After", str(DEFAULT_RATE_LIMIT_RETRY))
        return ProblemError("rate_limited", message, headers={"Retry-After": retry})
    if status in (401, 403):
        return ProblemError("provider_unavailable", message, retryable=False)
    if status in (400, 404, 422):
        return ProblemError("invalid_request", message)
    return ProblemError("provider_error", message, retryable=True)


class CloudinaryAPI:
    def __init__(self, settings: CloudinarySettings, http: httpx.AsyncClient):
        self.settings = settings
        self.http = http
        self.auth = (settings.api_key, settings.api_secret.get_secret_value())
        self.base = "https://api.cloudinary.com"

    async def request(self, method: str, path: str, json: dict | None = None) -> httpx.Response:
        try:
            return await self.http.request(method, self.base + path, json=json, auth=self.auth)
        except httpx.TransportError as error:
            raise ProblemError("provider_unavailable", f"Cloudinary is unreachable ({type(error).__name__}).") from None

    async def asset(self, ref: AssetRef) -> Asset:
        path = f"/v1_1/{self.settings.cloud_name}/resources/{ref.resource_type}/upload/{ref.public_id}"
        response = await self.request("GET", path)
        if response.status_code == 404:
            raise ProblemError("invalid_request", "The input asset was not found; upload it before submitting.")
        if response.status_code != 200:
            raise problem(response)
        body = response.json()
        return Asset(asset_id=body["asset_id"], width=body.get("width"), height=body.get("height"),
                     bytes=int(body.get("bytes", 0)), duration=body.get("duration"))
