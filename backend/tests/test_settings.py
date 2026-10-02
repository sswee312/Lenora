import pytest
from pydantic import ValidationError

from lenora_backend.settings import CoreSettings, load_environment


def test_token_is_required(monkeypatch):
    with pytest.raises(ValidationError):
        CoreSettings()


def test_short_token_is_rejected(monkeypatch):
    monkeypatch.setenv("LENORA_TOKEN", "short")
    with pytest.raises(ValidationError):
        CoreSettings()


def test_development_defaults(monkeypatch):
    monkeypatch.setenv("LENORA_TOKEN", "x" * 43)
    s = CoreSettings()
    assert (s.env, s.bind_host, s.bind_port, s.docs_enabled) == ("development", "127.0.0.1", 8787, True)


def test_production_binds_platform_port(monkeypatch):
    monkeypatch.setenv("LENORA_TOKEN", "x" * 43)
    monkeypatch.setenv("LENORA_ENV", "production")
    monkeypatch.setenv("PORT", "9000")
    s = CoreSettings()
    assert (s.bind_host, s.bind_port, s.docs_enabled) == ("0.0.0.0", 9000, False)


def test_production_without_port_fails(monkeypatch):
    monkeypatch.setenv("LENORA_TOKEN", "x" * 43)
    monkeypatch.setenv("LENORA_ENV", "production")
    with pytest.raises(ValueError, match="PORT"):
        CoreSettings().bind_port


def test_development_reads_dotenv(monkeypatch, tmp_path):
    (tmp_path / ".env").write_text("LENORA_TOKEN=" + "d" * 43 + "\n")
    monkeypatch.chdir(tmp_path)
    assert load_environment().token.get_secret_value() == "d" * 43


def test_production_ignores_dotenv(monkeypatch, tmp_path):
    (tmp_path / ".env").write_text("LENORA_TOKEN=" + "d" * 43 + "\n")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("LENORA_ENV", "production")
    with pytest.raises(ValidationError):
        load_environment()


def test_real_environment_wins_over_dotenv(monkeypatch, tmp_path):
    (tmp_path / ".env").write_text("LENORA_TOKEN=" + "d" * 43 + "\n")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("LENORA_TOKEN", "e" * 43)
    assert load_environment().token.get_secret_value() == "e" * 43
