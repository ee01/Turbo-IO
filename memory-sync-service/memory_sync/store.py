"""SQLite commit path for memory batches. Projections can be rebuilt after the transaction."""

from __future__ import annotations

import json
import os
import secrets
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

from . import SCHEMA_VERSION
from .exporter import rebuild
from .protocol import ProtocolError, _identifier, parse_batch, sha256_hex

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS credentials (
    token_hash TEXT PRIMARY KEY,
    source_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS revisions (
    source_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    session_id TEXT NOT NULL,
    received_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    role TEXT NOT NULL,
    text TEXT NOT NULL,
    text_hash TEXT NOT NULL,
    seq INTEGER NOT NULL UNIQUE,
    PRIMARY KEY (source_id, event_id, revision)
);
CREATE TABLE IF NOT EXISTS records (
    source_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    session_id TEXT NOT NULL,
    received_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    role TEXT NOT NULL,
    text TEXT NOT NULL,
    text_hash TEXT NOT NULL,
    seq INTEGER NOT NULL,
    PRIMARY KEY (source_id, event_id)
);
CREATE TABLE IF NOT EXISTS batches (
    source_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    committed_at TEXT NOT NULL,
    ack_json TEXT NOT NULL,
    PRIMARY KEY (source_id, batch_id)
);
CREATE TABLE IF NOT EXISTS batch_items (
    source_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    PRIMARY KEY (source_id, batch_id, event_id, revision)
);
"""


class Store:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, mode=0o700, exist_ok=True)
        os.chmod(self.root, 0o700)
        for name in ("state", "inbox", "events", "daily"):
            path = self.root / name
            path.mkdir(mode=0o700, exist_ok=True)
            os.chmod(path, 0o700)
        self._lock = threading.Lock()
        self.db = sqlite3.connect(
            self.root / "state" / "receiver.sqlite",
            check_same_thread=False,
            isolation_level=None,
        )
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript(_SCHEMA)
        os.chmod(self.root / "state" / "receiver.sqlite", 0o600)
        with self._lock:
            self._rebuild()

    def close(self) -> None:
        self.db.close()

    def pair(self, source_id: str) -> str:
        source_id = _identifier(source_id, "source_id")
        token = "ms_" + secrets.token_urlsafe(32)
        now = _now()
        with self._lock:
            self.db.execute(
                "INSERT INTO credentials(token_hash, source_id, created_at) VALUES (?, ?, ?)",
                (sha256_hex(token.encode()), source_id, now),
            )
            self.db.commit()
        return token

    def revoke(self, token: str) -> bool:
        digest = sha256_hex(token.encode())
        with self._lock:
            cursor = self.db.execute(
                "UPDATE credentials SET revoked_at=? WHERE token_hash=? AND revoked_at IS NULL",
                (_now(), digest),
            )
            self.db.commit()
            return cursor.rowcount == 1

    def authenticate(self, token: str) -> str:
        if not isinstance(token, str) or not token or len(token) > 256:
            raise ProtocolError("unauthorized", 401)
        digest = sha256_hex(token.encode())
        row = self.db.execute(
            "SELECT source_id, revoked_at FROM credentials WHERE token_hash=?",
            (digest,),
        ).fetchone()
        if row is None or row["revoked_at"]:
            raise ProtocolError("unauthorized", 401)
        return row["source_id"]

    def commit_batch(self, source_id: str, batch_id: str, payload_hash: str, body: bytes) -> dict:
        source_id = _identifier(source_id, "source_id")
        batch_id = _identifier(batch_id, "batch_id")
        if not isinstance(payload_hash, str):
            raise ProtocolError("payload_hash_mismatch")
        events = parse_batch(body, source_id, batch_id, payload_hash.lower())
        with self._lock:
            return self._commit_locked(source_id, batch_id, payload_hash.lower(), body, events)

    def status(self) -> dict:
        with self._lock:
            last_seq = self.db.execute("SELECT COALESCE(MAX(seq), 0) AS n FROM revisions").fetchone()["n"]
            last_commit = self.db.execute("SELECT MAX(committed_at) AS t FROM batches").fetchone()["t"]
            return {
                "batchCount": self.db.execute("SELECT COUNT(*) AS n FROM batches").fetchone()["n"],
                "lastCommittedAt": last_commit,
                "lastSeq": last_seq,
                "projectionOk": self._meta("projection_ok", "1") == "1",
                "protocol": 1,
                "recordCount": self.db.execute("SELECT COUNT(*) AS n FROM records").fetchone()["n"],
                "revisionCount": self.db.execute("SELECT COUNT(*) AS n FROM revisions").fetchone()["n"],
                "schemaVersion": SCHEMA_VERSION,
                "service": "memory-sync",
            }

    def rebuild(self) -> None:
        with self._lock:
            self._rebuild()

    def _commit_locked(self, source_id: str, batch_id: str, payload_hash: str, body: bytes, events: list[dict]) -> dict:
        inbox = self.root / "inbox" / source_id / f"{batch_id}.jsonl"
        created = False
        try:
            if inbox.exists():
                if inbox.read_bytes() != body:
                    raise ProtocolError("batch_conflict", 409)
            else:
                _write_private(inbox, body)
                created = True
            self.db.execute("BEGIN IMMEDIATE")
            existing = self._batch(source_id, batch_id)
            if existing is not None:
                self.db.execute("ROLLBACK")
                if existing["payload_hash"] != payload_hash:
                    if created and inbox.exists():
                        inbox.unlink()
                    raise ProtocolError("batch_conflict", 409)
                if self._meta("projection_ok", "1") != "1":
                    self._rebuild()
                return json.loads(existing["ack_json"])
            confirmed = [self._apply_event(source_id, event) for event in events]
            for item in confirmed:
                self.db.execute(
                    """INSERT INTO batch_items(source_id, batch_id, event_id, revision, seq)
                       VALUES (?, ?, ?, ?, ?)""",
                    (source_id, batch_id, item["eventId"], item["revision"], item["seq"]),
                )
            committed_at = _now()
            ack = {
                "batchId": batch_id,
                "committedAt": committed_at,
                "events": confirmed,
                "payloadHash": payload_hash,
                "schemaVersion": SCHEMA_VERSION,
                "sourceId": source_id,
            }
            self.db.execute(
                """INSERT INTO batches(source_id, batch_id, payload_hash, committed_at, ack_json)
                   VALUES (?, ?, ?, ?, ?)""",
                (source_id, batch_id, payload_hash, committed_at, json.dumps(ack, ensure_ascii=False, sort_keys=True)),
            )
            self.db.execute("COMMIT")
        except Exception:
            if self.db.in_transaction:
                self.db.execute("ROLLBACK")
            if created and self._batch(source_id, batch_id) is None and inbox.exists():
                inbox.unlink()
            raise
        self._rebuild()
        return ack

    def _apply_event(self, source_id: str, event: dict) -> dict:
        found = self.db.execute(
            """SELECT text_hash, seq FROM revisions
               WHERE source_id=? AND event_id=? AND revision=?""",
            (source_id, event["eventId"], event["revision"]),
        ).fetchone()
        if found is not None:
            if found["text_hash"] != event["textHash"]:
                raise ProtocolError("revision_conflict", 409)
            seq = found["seq"]
        else:
            seq = self.db.execute("SELECT COALESCE(MAX(seq), 0) + 1 AS n FROM revisions").fetchone()["n"]
            self.db.execute(
                """INSERT INTO revisions(source_id, event_id, revision, session_id, received_at, updated_at,
                                          role, text, text_hash, seq)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    source_id, event["eventId"], event["revision"], event["sessionId"],
                    event["receivedAt"], event["updatedAt"], event["role"], event["text"],
                    event["textHash"], seq,
                ),
            )
            self.db.execute(
                """INSERT INTO records(source_id, event_id, revision, session_id, received_at, updated_at,
                                        role, text, text_hash, seq)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(source_id, event_id) DO UPDATE SET
                     revision=excluded.revision,
                     session_id=excluded.session_id,
                     received_at=excluded.received_at,
                     updated_at=excluded.updated_at,
                     role=excluded.role,
                     text=excluded.text,
                     text_hash=excluded.text_hash,
                     seq=excluded.seq
                   WHERE excluded.revision >= records.revision""",
                (
                    source_id, event["eventId"], event["revision"], event["sessionId"],
                    event["receivedAt"], event["updatedAt"], event["role"], event["text"],
                    event["textHash"], seq,
                ),
            )
        return {"eventId": event["eventId"], "revision": event["revision"], "seq": seq}

    def _batch(self, source_id: str, batch_id: str):
        return self.db.execute(
            "SELECT payload_hash, ack_json FROM batches WHERE source_id=? AND batch_id=?",
            (source_id, batch_id),
        ).fetchone()

    def _rebuild(self) -> None:
        try:
            rebuild(self.db, self.root)
        except Exception:
            self._set_meta("projection_ok", "0")
            self.db.commit()
            return
        self._set_meta("projection_ok", "1")
        self.db.commit()

    def _meta(self, key: str, default: str) -> str:
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row["value"] if row else default

    def _set_meta(self, key: str, value: str) -> None:
        self.db.execute(
            "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _write_private(path: Path, body: bytes) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, body)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    os.chmod(path, 0o600)
