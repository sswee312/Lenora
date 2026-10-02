"""Create or complete .env from .env.example without touching values the user set."""
import os
import secrets
from pathlib import Path


def ensure_env(root: Path) -> list[str]:
    env_path = root / ".env"
    if not env_path.exists():
        fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write((root / ".env.example").read_text())
    os.chmod(env_path, 0o600)
    lines = env_path.read_text().splitlines()
    filled = []
    for i, line in enumerate(lines):
        if line.strip() == "LENORA_TOKEN=":
            lines[i] = f"LENORA_TOKEN={secrets.token_urlsafe(32)}"
            filled.append("LENORA_TOKEN")
    env_path.write_text("\n".join(lines) + "\n")
    return filled
