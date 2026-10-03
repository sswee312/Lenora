"""Background voiceover jobs: one task per job, at most MAX_RUNNING OpenAI calls at once. The table lives in memory;
a result that reached the store outlives it, a job that was still running does not."""
import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Literal

from lenora_backend.errors import ProblemError, RequestNotSent
from lenora_backend.kinds import JobError
from lenora_backend.results import TTL_SECONDS
from lenora_adapter_openai.api import Refused

log = logging.getLogger("lenora.openai")

# Each call holds one OpenAI connection for up to ~90 s and buffers up to 25 MB: 4 caps that at 100 MB.
MAX_RUNNING = 4
# Queued plus running; bounds memory and the worst-case wait (32 / 4 × ~90 s ≈ 12 min).
MAX_PENDING = 32
# Finished failed or cancelled entries kept for status; pruned ones report "not available".
MAX_FINISHED = 256
ADMISSION_RETRY_SECONDS = 10
LIVE = ("queued", "running")


@dataclass
class SpeechJob:
    status: Literal["queued", "running", "failed", "cancelled"] = "queued"
    phase: Literal["queued", "request", "store"] = "queued"
    error: JobError | None = None
    finished_at: float = 0.0
    refund: Callable[[], None] = field(default=lambda: None, repr=False)
    task: asyncio.Task | None = field(default=None, repr=False)


class SpeechJobs:
    def __init__(self, clock: Callable[[], float]):
        self.clock = clock
        self._jobs: dict[str, SpeechJob] = {}
        self._slots = asyncio.Semaphore(MAX_RUNNING)
        self._stopped = False

    def admit(self) -> None:
        """Refuse a job before anything is reserved. Call `launch` with no await in between."""
        if self._stopped:
            raise ProblemError("provider_unavailable", "The backend is shutting down.")
        self._prune()
        if sum(job.status in LIVE for job in self._jobs.values()) >= MAX_PENDING:
            raise ProblemError("rate_limited", "Too many voiceovers are in progress; try again shortly.",
                               headers={"Retry-After": str(ADMISSION_RETRY_SECONDS)})

    def launch(self, result_id: str, work: Callable[[SpeechJob], Awaitable[None]], refund: Callable[[], None]) -> None:
        job = SpeechJob(refund=refund)
        self._jobs[result_id] = job
        job.task = asyncio.create_task(self._run(result_id, job, work), name=f"openai-speech-{result_id}")

    def get(self, result_id: str) -> SpeechJob | None:
        return self._jobs.get(result_id)

    async def cancel(self, result_id: str) -> None:
        """Cancel a live job and wait until its task has cleaned up."""
        job = self._jobs.get(result_id)
        if job is not None and job.status in LIVE and job.task is not None:
            job.task.cancel()
            await asyncio.wait({job.task})
            # A task cancelled before its first step never ran `_run`, so settle it here.
            if job.status == "queued" and not self._stopped:
                job.refund()
                self._finish(job, "cancelled")

    async def join(self) -> None:
        """Wait for every task to end."""
        tasks = {job.task for job in self._jobs.values() if job.task is not None and not job.task.done()}
        if tasks:
            await asyncio.wait(tasks)

    async def stop(self) -> None:
        """Cancel every task and wait; from here on no task changes the table, the budget or the store."""
        self._stopped = True
        for job in self._jobs.values():
            if job.task is not None:
                job.task.cancel()
        await self.join()

    async def _run(self, result_id: str, job: SpeechJob, work: Callable[[SpeechJob], Awaitable[None]]) -> None:
        try:
            async with self._slots:
                job.status, job.phase = "running", "request"
                await work(job)
        except asyncio.CancelledError:
            if not self._stopped:
                if job.status == "queued":
                    job.refund()
                self._finish(job, "cancelled")
            raise
        except Exception as error:
            if not self._stopped:
                self._fail(result_id, job, error)
        else:
            if not self._stopped:
                del self._jobs[result_id]

    def _fail(self, result_id: str, job: SpeechJob, error: Exception) -> None:
        if isinstance(error, (RequestNotSent, Refused)):
            job.refund()
        if isinstance(error, ProblemError):
            failure, reason = JobError(code=error.code, message=error.detail, retryable=error.retryable), error.code
        else:
            failure = JobError(code="provider_error", message="The voiceover failed unexpectedly.", retryable=False)
            reason = type(error).__name__
        log.warning("speech job %s failed in %s: %s", result_id, job.phase, reason)
        self._finish(job, "failed", failure)

    def _finish(self, job: SpeechJob, status: Literal["failed", "cancelled"], error: JobError | None = None) -> None:
        job.status, job.error, job.finished_at = status, error, self.clock()

    def _prune(self) -> None:
        now = self.clock()
        # Stable sort: equal finish times keep launch order.
        finished = sorted(((rid, job) for rid, job in self._jobs.items() if job.status not in LIVE),
                          key=lambda item: item[1].finished_at)
        excess = len(finished) - MAX_FINISHED
        for index, (rid, job) in enumerate(finished):
            if index < excess or now - job.finished_at > TTL_SECONDS:
                del self._jobs[rid]
