"""Batch JSONL validation. payloadHash is the SHA-256 of the raw file bytes."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime

from . import MAX_BATCH_BYTES, MAX_BATCH_EVENTS, SCHEMA_VERSION

_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:|-]{0,127}$")


class ProtocolError(Exception):
    def __init__(self, code: str, status: int = 400):
        super().__init__(code)
        self.code = code
        self.status = status


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def text_hash(text: str) -> str:
    return sha256_hex(text.encode("utf-8"))


def encode_batch(source_id: str, batch_id: str, events: list[dict]) -> bytes:
    header = {
        "batchId": batch_id,
        "eventCount": len(events),
        "schemaVersion": SCHEMA_VERSION,
        "sourceId": source_id,
        "type": "batch",
    }
    lines = [_dumps(header)]
    for event in events:
        lines.append(_dumps(event))
    return ("\n".join(lines) + "\n").encode("utf-8")


def _dumps(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _parse_time(value: object, code: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise ProtocolError(code)
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError as exc:
        raise ProtocolError(code) from exc
    if parsed.tzinfo is None:
        raise ProtocolError("naive_timestamp")
    return parsed


def _identifier(value: object, code: str) -> str:
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ProtocolError(code)
    return value


def parse_batch(body: bytes, source_id: str, batch_id: str, payload_hash: str) -> list[dict]:
    if not isinstance(body, (bytes, bytearray)):
        raise ProtocolError("body_required")
    if len(body) > MAX_BATCH_BYTES:
        raise ProtocolError("batch_too_large", 413)
    if sha256_hex(body) != payload_hash:
        raise ProtocolError("payload_hash_mismatch")
    try:
        text = body.decode("utf-8")
    except UnicodeError as exc:
        raise ProtocolError("utf8_required") from exc
    if not text.endswith("\n") or "\r" in text:
        raise ProtocolError("jsonl_newline")
    raw_lines = text.split("\n")[:-1]
    if not raw_lines or len(raw_lines) > MAX_BATCH_EVENTS + 1:
        raise ProtocolError("event_count")
    try:
        header = json.loads(raw_lines[0])
    except json.JSONDecodeError as exc:
        raise ProtocolError("invalid_json") from exc
    if not isinstance(header, dict) or header.get("type") != "batch":
        raise ProtocolError("batch_header_required")
    if header.get("schemaVersion") != SCHEMA_VERSION:
        raise ProtocolError("schema_version")
    if header.get("sourceId") != source_id or header.get("batchId") != batch_id:
        raise ProtocolError("batch_identity")
    events: list[dict] = []
    seen: set[tuple[str, int]] = set()
    for line in raw_lines[1:]:
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ProtocolError("invalid_json") from exc
        events.append(_event(item, source_id, seen))
    if header.get("eventCount") != len(events):
        raise ProtocolError("event_count")
    if not events:
        raise ProtocolError("event_count")
    return events


def _event(item: object, source_id: str, seen: set[tuple[str, int]]) -> dict:
    if not isinstance(item, dict) or item.get("type") not in (None, "event"):
        raise ProtocolError("event_shape")
    if item.get("schemaVersion") != SCHEMA_VERSION:
        raise ProtocolError("schema_version")
    if item.get("sourceId") != source_id:
        raise ProtocolError("source_mismatch")
    event_id = _identifier(item.get("eventId"), "event_id")
    session_id = _identifier(item.get("sessionId"), "session_id")
    revision = item.get("revision")
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 1 or revision > 1_000_000:
        raise ProtocolError("revision")
    key = (event_id, revision)
    if key in seen:
        raise ProtocolError("duplicate_event_in_batch")
    seen.add(key)
    role = item.get("role")
    text = item.get("text")
    if not isinstance(role, str) or not role or len(role) > 80:
        raise ProtocolError("role")
    if not isinstance(text, str) or not text or len(text) > 32000:
        raise ProtocolError("text")
    digest = item.get("textHash")
    if digest != text_hash(text):
        raise ProtocolError("text_hash")
    received = _parse_time(item.get("receivedAt"), "received_at")
    updated = _parse_time(item.get("updatedAt"), "updated_at")
    return {
        "eventId": event_id,
        "revision": revision,
        "sessionId": session_id,
        "role": role,
        "text": text,
        "textHash": digest,
        "receivedAt": received.isoformat(),
        "updatedAt": updated.isoformat(),
    }
