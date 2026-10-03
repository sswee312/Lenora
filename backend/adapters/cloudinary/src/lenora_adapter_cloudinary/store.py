import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path

CHAIN_RETENTION_SECONDS = 7 * 86400


@dataclass(frozen=True)
class Chain:
    id: str
    stage: str
    gen_task_id: str
    i2v_id: str | None
    params: dict


@dataclass(frozen=True)
class Analysis:
    id: str
    endpoint: str
    task_id: str | None
    result: dict | None


class Store:
    """The adapter's only durable state: chain jobs and learned add-on availability. Single instance."""

    def __init__(self, path: Path, now: float):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        self._db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS chains (
                id TEXT PRIMARY KEY, stage TEXT NOT NULL, gen_task_id TEXT NOT NULL,
                i2v_id TEXT, params TEXT NOT NULL, created_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS addon_state (
                addon TEXT PRIMARY KEY, code TEXT NOT NULL, since REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS analyses (
                id TEXT PRIMARY KEY, endpoint TEXT NOT NULL, task_id TEXT,
                result TEXT, created_at REAL NOT NULL);
        """)
        self._db.execute("DELETE FROM chains WHERE created_at < ?", (now - CHAIN_RETENTION_SECONDS,))
        self._db.execute("DELETE FROM analyses WHERE created_at < ?", (now - CHAIN_RETENTION_SECONDS,))

    def insert_chain(self, chain_id: str, gen_task_id: str, params: dict, now: float) -> None:
        self._db.execute("INSERT INTO chains VALUES (?, 'image', ?, NULL, ?, ?)",
                         (chain_id, gen_task_id, json.dumps(params), now))

    def chain(self, chain_id: str) -> Chain | None:
        row = self._db.execute("SELECT id, stage, gen_task_id, i2v_id, params FROM chains WHERE id = ?",
                               (chain_id,)).fetchone()
        return Chain(row[0], row[1], row[2], row[3], json.loads(row[4])) if row else None

    def advance_chain(self, chain_id: str, i2v_id: str) -> None:
        self._db.execute("UPDATE chains SET stage = 'video', i2v_id = ? WHERE id = ? AND stage = 'image'",
                         (i2v_id, chain_id))

    def unavailable_addons(self) -> dict[str, str]:
        return dict(self._db.execute("SELECT addon, code FROM addon_state").fetchall())

    def mark_unavailable(self, addon: str, code: str, now: float) -> None:
        self._db.execute("INSERT OR REPLACE INTO addon_state VALUES (?, ?, ?)", (addon, code, now))

    def clear_addons(self) -> None:
        self._db.execute("DELETE FROM addon_state")

    def insert_analysis(self, analysis_id: str, endpoint: str, task_id: str | None, result: dict | None, now: float) -> None:
        self._db.execute("INSERT INTO analyses VALUES (?, ?, ?, ?, ?)",
                         (analysis_id, endpoint, task_id, None if result is None else json.dumps(result), now))

    def analysis(self, analysis_id: str) -> Analysis | None:
        row = self._db.execute("SELECT id, endpoint, task_id, result FROM analyses WHERE id = ?", (analysis_id,)).fetchone()
        if row is None:
            return None
        return Analysis(row[0], row[1], row[2], json.loads(row[3]) if row[3] else None)

    def save_analysis(self, analysis_id: str, result: dict) -> None:
        self._db.execute("UPDATE analyses SET result = ? WHERE id = ?", (json.dumps(result), analysis_id))
