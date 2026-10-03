import os
import subprocess
from pathlib import Path

HELPER = Path(__file__).parent / "dev-env.sh"
ENV_FILE = """# Lenora dev settings
LENORA_TOKEN=tok-0123456789abcdef0123456789abcdef

LENORA_ENV=development
LENORA_CLOUDINARY_API_SECRET=from-env-file
export LENORA_CLOUDINARY_API_KEY=key
PROVIDER_ONLY_SECRET=other
OPENAI_API_KEY=sk-openai
"""


def child_names(tmp_path, parent_env):
    env_file = tmp_path / ".env"
    env_file.write_text(ENV_FILE)
    script = (
        'set -euo pipefail; source "$1"; source "$2"; lenora_app_env "$2" http://127.0.0.1:8787; '
        'exec env "${app_env[@]}" /bin/sh -c "env | cut -d= -f1"'
    )
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path), **parent_env}
    out = subprocess.run(
        ["/bin/bash", "-c", script, "dev-env-test", str(HELPER), str(env_file)],
        env=env, capture_output=True, text=True, check=True,
    ).stdout
    return set(out.split())


def test_child_sees_only_allowed_names_even_when_parent_exports_secrets(tmp_path):
    names = child_names(tmp_path, {
        "LENORA_CLOUDINARY_API_SECRET": "exported-by-direnv",
        "PROVIDER_ONLY_SECRET": "exported",
        "LENORA_STRAY_PROVIDER_KEY": "not-in-env-file",
        "KEEP_ME": "1",
    })
    assert {n for n in names if n.startswith("LENORA_")} == {"LENORA_BACKEND_URL", "LENORA_TOKEN"}
    assert "PROVIDER_ONLY_SECRET" not in names
    assert "OPENAI_API_KEY" in names
    assert "ANTHROPIC_API_KEY" not in names
    assert "KEEP_ME" in names


def test_agent_keys_are_passed_only_when_set(tmp_path):
    names = child_names(tmp_path, {"ANTHROPIC_API_KEY": "sk-ant"})
    assert {"ANTHROPIC_API_KEY", "OPENAI_API_KEY"} <= names
