import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from bootstrap_env import ensure_env  # noqa: E402

EXAMPLE = "LENORA_TOKEN=\nLENORA_ENV=development\nLENORA_CLOUDINARY_API_KEY=\n"


def test_creates_env_with_generated_token(tmp_path):
    (tmp_path / ".env.example").write_text(EXAMPLE)
    assert ensure_env(tmp_path) == ["LENORA_TOKEN"]
    lines = dict(l.split("=", 1) for l in (tmp_path / ".env").read_text().splitlines() if "=" in l)
    assert len(lines["LENORA_TOKEN"]) >= 43
    assert lines["LENORA_CLOUDINARY_API_KEY"] == ""


def test_is_idempotent_and_keeps_user_values(tmp_path):
    (tmp_path / ".env.example").write_text(EXAMPLE)
    (tmp_path / ".env").write_text("LENORA_TOKEN=keep-me-" + "x" * 40 + "\nLENORA_CLOUDINARY_API_KEY=abc\n")
    assert ensure_env(tmp_path) == []
    text = (tmp_path / ".env").read_text()
    assert "keep-me-" in text and "LENORA_CLOUDINARY_API_KEY=abc" in text


def test_env_file_is_private(tmp_path):
    (tmp_path / ".env.example").write_text(EXAMPLE)
    ensure_env(tmp_path)
    assert (tmp_path / ".env").stat().st_mode & 0o077 == 0
