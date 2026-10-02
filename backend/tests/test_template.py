import sys
from pathlib import Path

TEMPLATE_SRC = Path(__file__).resolve().parents[1] / "adapters/_template/src"


def test_template_declares_the_adapter_contract(monkeypatch):
    monkeypatch.syspath_prepend(str(TEMPLATE_SRC))
    from lenora_adapter_template import TemplateAdapter, TemplateSettings
    from lenora_backend.registry import CancelNotSupported

    assert TemplateAdapter.id == "template"
    assert TemplateAdapter.Settings is TemplateSettings
    assert issubclass(TemplateAdapter, CancelNotSupported)
    for name in ("models", "create_upload", "submit", "status", "cancel"):
        assert callable(getattr(TemplateAdapter, name))
