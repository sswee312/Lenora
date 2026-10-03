import base64
import binascii
import hashlib
from urllib.parse import quote

from lenora_backend.kinds import EditOp

CONTENT_TYPES = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "mp4": "video/mp4"}


def sign_upload(params: dict[str, str], secret: str) -> str:
    """Cloudinary upload signature: sha1 of sorted k=v pairs joined by & plus the API secret."""
    payload = "&".join(f"{k}={params[k]}" for k in sorted(params))
    return hashlib.sha1((payload + secret).encode()).hexdigest()


def signed_url(cloud_name: str, resource_type: str, transformation: str, path: str, secret: str) -> str:
    """Delivery URL with an `s--<8>--` signature over `<transformation>/<public_id>.<ext>`."""
    to_sign = f"{transformation}/{path}"
    digest = base64.urlsafe_b64encode(hashlib.sha1((to_sign + secret).encode()).digest()).decode()[:8]
    return f"https://res.cloudinary.com/{cloud_name}/{resource_type}/upload/s--{digest}--/{to_sign}"


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


def decode_url_job(job_id: str) -> str | None:
    if not job_id.startswith("url:") or len(job_id) <= 4:
        return None
    encoded = job_id[4:]
    try:
        return base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode()
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
