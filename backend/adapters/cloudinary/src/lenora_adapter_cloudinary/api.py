import re
from dataclasses import dataclass

import httpx

from lenora_backend.errors import NOT_SENT, ProblemError, RequestNotSent
from lenora_backend.kinds import AssetInput, UrlInput
from lenora_adapter_cloudinary.delivery import PUBLIC_ID_PATTERN, sign_upload
from lenora_adapter_cloudinary.settings import CloudinarySettings

PUBLIC_ID = re.compile(PUBLIC_ID_PATTERN)
ASSET_REF = re.compile(rf"(image|video)/upload/({PUBLIC_ID_PATTERN})")
DEFAULT_RATE_LIMIT_RETRY = 30


class AssetNotFound(ProblemError):
    """Cloudinary answered 404: the asset does not exist (any other refusal is not proof it is gone)."""


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
    format: str | None = None
    derived: tuple[tuple[str, str | None], ...] = ()


def parse_ref(item: AssetInput | UrlInput, resource_type: str) -> AssetRef:
    match = ASSET_REF.fullmatch(item.assetRef) if isinstance(item, AssetInput) else None
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


def is_subscription_refusal(response: httpx.Response) -> bool:
    # The spike (plan Task 1) pins the exact refusal; update this one rule if it differs.
    return response.status_code in (401, 403)


class CloudinaryAPI:
    def __init__(self, settings: CloudinarySettings, http: httpx.AsyncClient):
        self.settings = settings
        self.http = http
        self.auth = (settings.api_key, settings.api_secret.get_secret_value())
        self.base = "https://api.cloudinary.com"

    async def request(self, method: str, path: str, json: dict | None = None, data: dict | None = None) -> httpx.Response:
        try:
            return await self.http.request(method, self.base + path, json=json, data=data, auth=self.auth)
        except httpx.TransportError as error:
            kind = RequestNotSent if isinstance(error, NOT_SENT) else ProblemError
            raise kind("provider_unavailable", f"Cloudinary is unreachable ({type(error).__name__}).") from None

    async def usage(self) -> dict:
        response = await self.request("GET", f"/v1_1/{self.settings.cloud_name}/usage")
        if response.status_code != 200:
            raise problem(response)
        body = response.json()
        if not isinstance(body, dict):
            raise ProblemError("provider_error", "Cloudinary usage report was not an object.", retryable=True)
        return body

    async def analyze(self, endpoint: str, body: dict) -> httpx.Response:
        return await self.request("POST", f"/v2/analysis/{self.settings.cloud_name}/analyze/{endpoint}", json=body)

    async def analysis_task(self, task_id: str) -> httpx.Response:
        return await self.request("GET", f"/v2/analysis/{self.settings.cloud_name}/tasks/{task_id}")

    async def explicit(self, public_id: str, timestamp: str, extra: dict[str, str]) -> httpx.Response:
        signed = {"public_id": public_id, "type": "upload", "timestamp": timestamp, **extra}
        fields = {**signed, "api_key": self.settings.api_key,
                  "signature": sign_upload(signed, self.settings.api_secret.get_secret_value())}
        return await self.request("POST", f"/v1_1/{self.settings.cloud_name}/image/explicit", data=fields)

    async def asset(self, ref: AssetRef, *, duration: bool = False) -> Asset:
        path = f"/v1_1/{self.settings.cloud_name}/resources/{ref.resource_type}/upload/{ref.public_id}"
        if duration:
            path += "?media_metadata=true"  # without it a video lookup omits duration
        response = await self.request("GET", path)
        if response.status_code == 404:
            raise AssetNotFound("invalid_request", "The input asset was not found; upload it before submitting.")
        if response.status_code != 200:
            raise problem(response)
        body = response.json()
        derived = tuple((d["transformation"], d.get("format")) for d in body.get("derived") or [] if d.get("transformation"))
        return Asset(asset_id=body["asset_id"], width=body.get("width"), height=body.get("height"),
                     bytes=int(body.get("bytes", 0)), duration=body.get("duration"), format=body.get("format"),
                     derived=derived)
