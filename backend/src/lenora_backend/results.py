"""Provider-neutral store for adapter results that arrive as bytes or text instead of URLs."""
import asyncio
import json
import os
import re
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from lenora_backend.errors import ProblemError
from lenora_backend.kinds import JobResult

MAX_BYTES = 25 * 1024 * 1024
TTL_SECONDS = 24 * 3600
STRAY_SECONDS = 3600
# Reserved TLD (RFC 2606): the marker can never resolve; the jobs route always rewrites it.
MARKER_HOST = "lenora-result.invalid"
TEXT_TYPE = "text/plain; charset=utf-8"
_ID = re.compile(r"[0-9a-f]{32}")


@dataclass(frozen=True)
class StoredResult:
    path: Path
    content_type: str
    file_extension: str


def _not_found() -> ProblemError:
    return ProblemError("not_found", "Unknown or expired result.")


class ResultStore:
    """`<id>.data` plus a `<id>.json` sidecar, each installed by atomic rename; the sidecar is written last."""

    def __init__(self, root: Path, clock: Callable[[], float] = time.time):
        self.root = root
        self.clock = clock

    async def put_bytes(self, data: bytes, content_type: str, file_extension: str) -> str:
        if len(data) > MAX_BYTES:
            raise ProblemError("provider_error", "The provider returned a result larger than 25 MB.", retryable=False)
        return await asyncio.to_thread(self._put, data, content_type, file_extension)

    async def put_text(self, text: str) -> str:
        return await self.put_bytes(text.encode(), TEXT_TYPE, "txt")

    async def open(self, result_id: str) -> StoredResult:
        return await asyncio.to_thread(self._open, result_id)

    async def read_text(self, result_id: str) -> str:
        def read() -> str:
            try:
                return self._open(result_id).path.read_text(encoding="utf-8")
            except FileNotFoundError:
                raise _not_found() from None
        return await asyncio.to_thread(read)

    async def sweep(self) -> int:
        return await asyncio.to_thread(self._sweep)

    @staticmethod
    def result(result_id: str, content_type: str, file_extension: str) -> JobResult:
        return JobResult(url=f"https://{MARKER_HOST}/{result_id}", contentType=content_type, fileExtension=file_extension)

    @staticmethod
    def resolve(result: JobResult, base_url: str) -> JobResult:
        if result.url.host != MARKER_HOST:
            return result
        return JobResult.model_validate({**result.model_dump(), "url": f"{base_url}v1/results/{result.url.path.lstrip('/')}"})

    def _put(self, data: bytes, content_type: str, file_extension: str) -> str:
        self.root.mkdir(parents=True, exist_ok=True)
        result_id = secrets.token_hex(16)
        self._install(self.root / f"{result_id}.data", data)
        meta = {"contentType": content_type, "fileExtension": file_extension, "createdAt": self.clock()}
        self._install(self.root / f"{result_id}.json", json.dumps(meta).encode())
        return result_id

    def _install(self, target: Path, data: bytes) -> None:
        temp = target.with_name(f".{secrets.token_hex(8)}.tmp")
        try:
            with open(temp, "xb") as file:
                file.write(data)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temp, target)
        except BaseException:
            temp.unlink(missing_ok=True)
            raise

    def _open(self, result_id: str) -> StoredResult:
        if not _ID.fullmatch(result_id):
            raise _not_found()
        try:
            meta = json.loads((self.root / f"{result_id}.json").read_bytes())
            created, content_type, extension = float(meta["createdAt"]), meta["contentType"], meta["fileExtension"]
        except (FileNotFoundError, ValueError, KeyError, TypeError):
            raise _not_found() from None
        path = self.root / f"{result_id}.data"
        if self.clock() - created > TTL_SECONDS or not path.is_file():
            raise _not_found()
        return StoredResult(path, content_type, extension)

    def _sweep(self) -> int:
        if not self.root.is_dir():
            return 0
        now, removed = self.clock(), 0
        for path in list(self.root.iterdir()):
            try:
                if path.suffix == ".json":
                    try:
                        expired = now - float(json.loads(path.read_bytes())["createdAt"]) > TTL_SECONDS
                    except (ValueError, KeyError, TypeError):
                        expired = time.time() - path.stat().st_mtime > STRAY_SECONDS
                    if expired:
                        path.with_suffix(".data").unlink(missing_ok=True)
                        path.unlink()
                        removed += 1
                elif path.suffix == ".tmp" or (path.suffix == ".data" and not path.with_suffix(".json").exists()):
                    if time.time() - path.stat().st_mtime > STRAY_SECONDS:
                        path.unlink()
                        removed += 1
            except FileNotFoundError:
                continue
        return removed
