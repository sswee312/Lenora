import asyncio
import time
from collections.abc import Awaitable, Callable

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import SubmittedJob


class IdempotencyStore:
    """In-memory Idempotency-Key → job map. Single-instance only."""

    def __init__(self, ttl_seconds: float = 86400, clock: Callable[[], float] = time.monotonic):
        self._ttl = ttl_seconds
        self._clock = clock
        self._entries: dict[str, tuple[float, str, SubmittedJob]] = {}
        # ponytail: one global lock serializes submits; move to per-key locks or a shared store for multi-instance hosting.
        self._lock = asyncio.Lock()

    async def run(self, key: str, fingerprint: str, submit: Callable[[], Awaitable[SubmittedJob]]) -> SubmittedJob:
        async with self._lock:
            now = self._clock()
            self._entries = {k: v for k, v in self._entries.items() if v[0] > now}
            if key in self._entries:
                _, stored_fingerprint, job = self._entries[key]
                if stored_fingerprint != fingerprint:
                    raise ProblemError("invalid_request", "Idempotency-Key was already used with a different request.")
                return job
            job = await submit()
            self._entries[key] = (now + self._ttl, fingerprint, job)
            return job
