"""Daily spend cap shared by adapters."""
import threading
from collections.abc import Callable
from datetime import UTC, datetime

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import Estimate


class Budget:
    """Optional daily cap in one estimate unit, reset at UTC midnight. In memory and single instance, like idempotency."""

    def __init__(self, limit: float | None, clock: Callable[[], float], *, provider: str, unit: str, label: str):
        self.limit = limit
        self.clock = clock
        self.provider = provider
        self.unit = unit
        self.label = label
        self._lock = threading.Lock()
        self._day = ""
        self._used = 0.0

    def _today(self) -> str:
        day = datetime.fromtimestamp(self.clock(), UTC).date().isoformat()
        if day != self._day:
            self._day, self._used = day, 0.0
        return day

    def reserve(self, estimate: Estimate) -> None:
        with self._lock:
            self._today()
            if self.limit is not None and self._used + estimate.amount > self.limit:
                remaining = max(0.0, self.limit - self._used)
                raise ProblemError("quota_exceeded", (
                    f"The daily {self.provider} budget is reached: "
                    f"{remaining:.3f} of {self.limit:g} {self.label} left today."
                ), retryable=False)
            self._used += estimate.amount

    def refund(self, estimate: Estimate) -> None:
        with self._lock:
            self._today()
            self._used = max(0.0, self._used - estimate.amount)

    def usage(self) -> dict:
        with self._lock:
            return {"limit": self.limit, "used": round(self._used, 6), "day": self._today(), "unit": self.unit}
