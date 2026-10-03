import pytest

from lenora_backend.jobids import sign_job, verify_job

SECRET = "abcd"


def test_round_trip():
    assert verify_job("speech", sign_job("speech", "0f" * 16, SECRET), SECRET) == "0f" * 16


def _flip_last(job_id: str) -> str:
    return job_id[:-1] + ("A" if job_id[-1] != "A" else "B")


@pytest.mark.parametrize("forge", [
    lambda j: j.removeprefix("speech:"),
    lambda j: j.replace("speech:", "rewrite:", 1),
    _flip_last,
    lambda j: j.replace(".", "x.", 1),
    lambda j: j.split(".")[0],
    lambda j: j + ".extra",
], ids=["unprefixed", "other-domain", "tampered-signature", "tampered-payload", "no-signature", "trailing"])
def test_forged_ids_do_not_verify(forge):
    assert verify_job("speech", forge(sign_job("speech", "x", SECRET)), SECRET) is None


def test_another_secret_does_not_verify():
    assert verify_job("speech", sign_job("speech", "x", "other"), SECRET) is None
