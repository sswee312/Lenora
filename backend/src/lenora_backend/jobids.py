"""Stateless job IDs for adapters that keep no job table: `<domain>:<base64 payload>.<HMAC-SHA256, 22 chars>`."""
import base64
import binascii
import hashlib
import hmac


def _signature(domain: str, payload: str, secret: str) -> str:
    digest = hmac.new(secret.encode(), f"{domain}:{payload}".encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode()[:22]


def sign_job(domain: str, raw: str, secret: str) -> str:
    """The domain tag keeps one kind's signature from validating as another's."""
    payload = base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")
    return f"{domain}:{payload}.{_signature(domain, payload, secret)}"


def verify_job(domain: str, job_id: str, secret: str) -> str | None:
    """The signed payload text, only if this backend signed it for this domain."""
    prefix, _, rest = job_id.partition(":")
    payload, _, signature = rest.partition(".")
    if prefix != domain or not payload or not hmac.compare_digest(_signature(domain, payload, secret).encode(), signature.encode()):
        return None
    try:
        return base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)).decode()
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
