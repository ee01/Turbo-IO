"""Rebuild the readable archive from committed rows. The database remains the source of truth."""

from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path

from . import SCHEMA_VERSION
from .protocol import _dumps


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def rebuild(connection, root: Path) -> None:
    revisions = connection.execute(
        """SELECT source_id, event_id, revision, session_id, received_at, updated_at,
                  role, text, text_hash, seq
           FROM revisions ORDER BY seq"""
    ).fetchall()
    records = connection.execute(
        """SELECT source_id, event_id, revision, session_id, received_at, updated_at,
                  role, text, seq
           FROM records ORDER BY received_at, event_id"""
    ).fetchall()
    zone = datetime.now().astimezone().tzinfo
    by_day: dict[str, list] = {}
    for row in revisions:
        day = datetime.fromisoformat(row["received_at"]).astimezone(zone).date().isoformat()
        by_day.setdefault(day, []).append(row)
    current_by_day: dict[str, list] = {}
    for row in records:
        day = datetime.fromisoformat(row["received_at"]).astimezone(zone).date().isoformat()
        current_by_day.setdefault(day, []).append(row)

    _replace_tree(root / "events", by_day, lambda day, rows: _event_document(rows))
    _replace_tree(root / "daily", current_by_day, lambda day, rows: _daily_document(day, rows, by_day.get(day, [])))

    last_seq = connection.execute("SELECT COALESCE(MAX(seq), 0) AS n FROM revisions").fetchone()["n"]
    last_commit = connection.execute("SELECT MAX(committed_at) AS t FROM batches").fetchone()["t"]
    manifest = {
        "batchCount": connection.execute("SELECT COUNT(*) AS n FROM batches").fetchone()["n"],
        "eventCount": len(revisions),
        "lastCommittedAt": last_commit,
        "lastSeq": last_seq,
        "recordCount": len(records),
        "schemaVersion": SCHEMA_VERSION,
    }
    atomic_write(root / "manifest.json", (_dumps(manifest) + "\n").encode("utf-8"))


def _event_document(rows: list) -> bytes:
    lines = []
    for row in rows:
        lines.append(_dumps({
            "eventId": row["event_id"],
            "receivedAt": row["received_at"],
            "revision": row["revision"],
            "role": row["role"],
            "schemaVersion": SCHEMA_VERSION,
            "seq": row["seq"],
            "sessionId": row["session_id"],
            "sourceId": row["source_id"],
            "text": row["text"],
            "textHash": row["text_hash"],
            "updatedAt": row["updated_at"],
        }))
    return ("\n".join(lines) + "\n").encode("utf-8")


def _daily_document(day: str, rows: list, revisions: list) -> bytes:
    sessions = sorted({row["session_id"] for row in rows})
    last_seq = max((row["seq"] for row in revisions), default=0)
    front = [
        "---",
        f"date: {day}",
        f"sessions: {len(sessions)}",
        f"eventCount: {len(rows)}",
        f"lastSeq: {last_seq}",
        "---",
        "",
        f"# {day}",
        "",
    ]
    grouped: dict[str, list] = {}
    for row in rows:
        grouped.setdefault(row["session_id"], []).append(row)
    for session_id in sessions:
        front.append(f"## 会话 {session_id}")
        front.append("")
        for row in grouped[session_id]:
            front.append(f"### {row['received_at']} · {row['role']} · rev {row['revision']}")
            front.append("")
            for line in str(row["text"]).split("\n"):
                front.append(f"> {line}")
            front.append("")
    return ("\n".join(front)).encode("utf-8")


def _replace_tree(root: Path, by_day: dict[str, list], render) -> None:
    expected: set[Path] = set()
    for day, rows in by_day.items():
        year = day[:4]
        path = root / year / f"{day}{'.jsonl' if root.name == 'events' else '.md'}"
        atomic_write(path, render(day, rows))
        expected.add(path.resolve())
    if not root.exists():
        return
    for path in root.rglob("*"):
        if path.is_file() and path.resolve() not in expected:
            path.unlink()
    for path in sorted(root.rglob("*"), reverse=True):
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()
