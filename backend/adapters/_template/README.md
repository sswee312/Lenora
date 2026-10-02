# Adapter template

1. Copy this directory to `backend/adapters/<id>/` and rename `lenora_adapter_template`, `TemplateAdapter`, the `template` id, the entry point and the `LENORA_TEMPLATE_` prefix.
2. Add `"adapters/<id>"` to `[tool.uv.workspace] members` in `backend/pyproject.toml`, plus a `[tool.uv.sources]` entry and a dev-group dependency, then run `uv sync`.
3. Implement `models`, `create_upload`, `submit` and `status`. Keep job IDs restart-safe.
4. In `tests/test_conformance.py`, fill in the request builders and the `respx` mocks for each scenario.
5. Run `uv run pytest adapters/<id>`. No app change is needed: the editor discovers your models through `/v1/capabilities`.
