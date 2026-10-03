import base64
import binascii
import hashlib
import hmac
import re
from urllib.parse import quote

from lenora_backend.kinds import EditOp

PUBLIC_ID_PATTERN = r"lenora/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

CONTENT_TYPES = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "mp4": "video/mp4",
                 "mov": "video/quicktime", "webm": "video/webm", "m3u8": "application/vnd.apple.mpegurl"}


def sign_upload(params: dict[str, str], secret: str) -> str:
    """Cloudinary upload signature: sha1 of sorted k=v pairs joined by & plus the API secret."""
    payload = "&".join(f"{k}={params[k]}" for k in sorted(params))
    return hashlib.sha1((payload + secret).encode()).hexdigest()


def signed_url(cloud_name: str, resource_type: str, transformation: str, path: str, secret: str) -> str:
    """Delivery URL with an `s--<8>--` signature over `[<transformation>/]<public_id>.<ext>`."""
    to_sign = f"{transformation}/{path}" if transformation else path
    digest = base64.urlsafe_b64encode(hashlib.sha1((to_sign + secret).encode()).digest()).decode()[:8]
    return f"https://res.cloudinary.com/{cloud_name}/{resource_type}/upload/s--{digest}--/{to_sign}"


def _job_signature(domain: str, payload: str, secret: str) -> str:
    digest = hmac.new(secret.encode(), f"{domain}:{payload}".encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode()[:22]


def sign_job(domain: str, raw: str, secret: str) -> str:
    """`<domain>:<payload>.<signature>`; the domain tag keeps one kind's signature from validating as another's."""
    payload = base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")
    return f"{domain}:{payload}.{_job_signature(domain, payload, secret)}"


def verify_job(domain: str, job_id: str, secret: str) -> str | None:
    """The signed payload text, only if this backend signed it for this domain."""
    prefix, _, rest = job_id.partition(":")
    payload, _, signature = rest.partition(".")
    if prefix != domain or not payload or not hmac.compare_digest(_job_signature(domain, payload, secret).encode(), signature.encode()):
        return None
    try:
        return base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)).decode()
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None


def _q(text: str) -> str:
    return quote(text, safe="")


def edit_transformation(op: EditOp) -> str:
    match op.op:
        case "fill":
            return f"ar_{op.aspectRatio},b_gen_fill,c_pad"
        case "replace":
            return f"e_gen_replace:from_{_q(op.from_)};to_{_q(op.to)}"
        case "remove":
            return f"e_gen_remove:prompt_{_q(op.prompt)}"
        case "recolor":
            return f"e_gen_recolor:prompt_{_q(op.prompt)};to-color_{op.color[1:].lower()}"
        case "backgroundReplace":
            return "e_gen_background_replace" + (f":prompt_{_q(op.prompt)}" if op.prompt else "")
        case "restore":
            return "e_gen_restore"
    raise ValueError(op.op)


def encode_url_job(url: str) -> str:
    return "url:" + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


DELIVERY_URL = re.compile(
    rf"https://res\.cloudinary\.com/([^/]+)/(image|video)/upload/s--[A-Za-z0-9_-]{{8}}--/(.+)/({PUBLIC_ID_PATTERN}\.([a-z0-9]+))")


def verify_url_job(job_id: str, cloud_name: str, secret: str) -> tuple[str, str] | None:
    """The job's delivery URL and extension, only if this adapter signed it for its own cloud."""
    url = decode_url_job(job_id)
    match = DELIVERY_URL.fullmatch(url or "")
    if not match:
        return None
    cloud, resource_type, transformation, path, extension = match.groups()
    if cloud != cloud_name or extension not in CONTENT_TYPES:
        return None
    if not hmac.compare_digest(signed_url(cloud, resource_type, transformation, path, secret), url):
        return None
    return url, extension


def decode_url_job(job_id: str) -> str | None:
    if not job_id.startswith("url:") or len(job_id) <= 4:
        return None
    encoded = job_id[4:]
    try:
        return base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
