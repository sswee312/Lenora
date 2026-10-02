import os
from contextlib import ExitStack

import pytest
from fastapi.testclient import TestClient

from fakes import build_app


@pytest.fixture(autouse=True)
def clean_lenora_env(monkeypatch):
    for key in list(os.environ):
        if key.startswith("LENORA_") or key == "PORT":
            monkeypatch.delenv(key)


@pytest.fixture
def make_client():
    """Build a TestClient with its lifespan running; closed at teardown."""
    with ExitStack() as stack:
        def factory(*adapters, statuses=None, **setting_overrides) -> TestClient:
            return stack.enter_context(TestClient(build_app(*adapters, statuses=statuses, **setting_overrides)))
        yield factory
