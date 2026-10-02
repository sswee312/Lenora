import json
from pathlib import Path

import pytest
import yaml
from jsonschema import Draft202012Validator, FormatChecker

from lenora_backend import kinds

PROTOCOL = Path(__file__).resolve().parents[2] / "protocol"
SPEC = yaml.safe_load((PROTOCOL / "openapi.yaml").read_text())
FIXTURES = sorted((PROTOCOL / "fixtures").glob("*.json"))


def validator(schema_name: str) -> Draft202012Validator:
    schema = {"$ref": f"#/components/schemas/{schema_name}", "components": SPEC["components"]}
    return Draft202012Validator(schema, format_checker=FormatChecker())


def test_fixtures_exist():
    assert len(FIXTURES) >= 11


@pytest.mark.parametrize("path", FIXTURES, ids=lambda p: p.name)
def test_fixture_matches_openapi(path):
    schema_name = path.name.split(".")[0]
    validator(schema_name).validate(json.loads(path.read_text()))


@pytest.mark.parametrize("path", FIXTURES, ids=lambda p: p.name)
def test_fixture_round_trips_through_kinds(path):
    schema_name = path.name.split(".")[0]
    data = json.loads(path.read_text())
    model = getattr(kinds, schema_name).model_validate(data)
    validator(schema_name).validate(model.model_dump(mode="json"))


def test_error_codes_match_openapi():
    from lenora_backend.errors import STATUS
    assert sorted(STATUS) == sorted(SPEC["components"]["schemas"]["ErrorCode"]["enum"])


def test_kinds_match_openapi_examples():
    from typing import get_args
    assert sorted(get_args(kinds.Kind)) == sorted(SPEC["components"]["schemas"]["Kind"]["examples"])
