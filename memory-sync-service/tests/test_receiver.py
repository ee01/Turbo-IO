import json
import logging
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from memory_sync.api import create_app
from memory_sync.cli import main
from memory_sync.protocol import encode_batch, sha256_hex, text_hash
from memory_sync.store import Store

SOURCE = "glasses-a"
SENTINEL = "SENTINEL_TEXT_SHOULD_NOT_LOG"
WHEN = "2026-10-09T12:00:00+00:00"


def event(event_id="sess-1:round-1|0", text="你好", revision=1, session="sess-1", received=WHEN, source=SOURCE):
    return {
        "eventId": event_id,
        "receivedAt": received,
        "revision": revision,
        "role": "0",
        "schemaVersion": 1,
        "sessionId": session,
        "sourceId": source,
        "text": text,
        "textHash": text_hash(text),
        "updatedAt": received,
    }


def body_for(batch, events, source=SOURCE):
    body = encode_batch(source, batch, events)
    return body, sha256_hex(body)


def test_health_and_auth_do_not_echo_text(tmp_path):
    store = Store(tmp_path)
    token = store.pair(SOURCE)
    client = TestClient(create_app(store))
    health = client.get("/v1/memory/health")
    assert health.status_code == 200
    assert health.json() == {"protocol": 1, "schemaVersion": 1, "service": "memory-sync", "status": "ok"}
    assert SENTINEL not in health.text
    missing = client.post("/v1/memory/batches", content=b"{}")
    assert missing.status_code == 401 and missing.json()["error"] == "unauthorized"
    other = store.pair("glasses-b")
    body, digest = body_for("batch-1", [event(text=SENTINEL)])
    rejected = client.post("/v1/memory/batches", content=body, headers=_headers(other, digest, "batch-1"))
    assert rejected.status_code == 403
    assert SENTINEL not in rejected.text
    assert list((tmp_path / "inbox").rglob("*.jsonl")) == []


def test_commit_retry_conflict_and_projection(tmp_path, caplog):
    store = Store(tmp_path)
    token = store.pair(SOURCE)
    client = TestClient(create_app(store))
    first, digest = body_for("batch-1", [event(text=SENTINEL)])
    with caplog.at_level(logging.INFO, logger="memory_sync"):
        response = client.post("/v1/memory/batches", content=first, headers=_headers(token, digest, "batch-1"))
    assert response.status_code == 200, response.text
    ack = response.json()
    assert ack["batchId"] == "batch-1" and ack["payloadHash"] == digest
    assert ack["events"] == [{"eventId": "sess-1:round-1|0", "revision": 1, "seq": 1}]
    assert SENTINEL not in response.text
    assert SENTINEL not in caplog.text
    retry = client.post("/v1/memory/batches", content=first, headers=_headers(token, digest, "batch-1"))
    assert retry.status_code == 200 and retry.json() == ack
    changed, changed_digest = body_for("batch-1", [event(text="另一份正文")])
    conflict = client.post("/v1/memory/batches", content=changed, headers=_headers(token, changed_digest, "batch-1"))
    assert conflict.status_code == 409 and conflict.json()["error"] == "batch_conflict"
    inbox = (tmp_path / "inbox" / SOURCE / "batch-1.jsonl").read_bytes()
    assert inbox == first
    assert (tmp_path / "inbox" / SOURCE / "batch-1.jsonl").stat().st_mode & 0o777 == 0o600
    manifest = json.loads((tmp_path / "manifest.json").read_text())
    assert manifest["lastSeq"] == 1 and manifest["eventCount"] == 1 and manifest["recordCount"] == 1
    daily = next((tmp_path / "daily").rglob("*.md")).read_text()
    assert "SENTINEL_TEXT_SHOULD_NOT_LOG" in daily and "lastSeq: 1" in daily
    streamed = next((tmp_path / "events").rglob("*.jsonl")).read_text()
    assert '"seq":1' in streamed and SENTINEL in streamed
    status = client_status(store)
    assert status["lastSeq"] == 1 and SENTINEL not in json.dumps(status)


def test_revision_order_reuse_and_atomic_conflict(tmp_path):
    store = Store(tmp_path)
    newer, newer_digest = body_for("batch-new", [event(text="新版本", revision=2)])
    assert store.commit_batch(SOURCE, "batch-new", newer_digest, newer)["events"][0]["seq"] == 1
    older, older_digest = body_for("batch-old", [event(text="旧版本", revision=1)])
    ack = store.commit_batch(SOURCE, "batch-old", older_digest, older)
    assert ack["events"][0]["seq"] == 2
    view = store.db.execute("SELECT revision, text FROM records").fetchone()
    assert view["revision"] == 2 and view["text"] == "新版本"
    assert store.db.execute("SELECT COUNT(*) AS n FROM revisions").fetchone()["n"] == 2
    replay, replay_digest = body_for("batch-replay", [event(text="新版本", revision=2)])
    replayed = store.commit_batch(SOURCE, "batch-replay", replay_digest, replay)
    assert replayed["batchId"] == "batch-replay"
    assert replayed["events"][0]["seq"] == 1
    assert store.status()["lastSeq"] == 2
    clash_events = [event(event_id="sess-1:round-2|0", text="应当回滚"), event(text="篡改", revision=2)]
    clash, clash_digest = body_for("batch-clash", clash_events)
    with pytest.raises(Exception) as caught:
        store.commit_batch(SOURCE, "batch-clash", clash_digest, clash)
    assert caught.value.code == "revision_conflict"
    assert store.db.execute("SELECT COUNT(*) AS n FROM records").fetchone()["n"] == 1
    assert not (tmp_path / "inbox" / SOURCE / "batch-clash.jsonl").exists()
    same, same_digest = body_for("batch-same-text", [event(event_id="sess-1:other|0", text="新版本")])
    store.commit_batch(SOURCE, "batch-same-text", same_digest, same)
    assert store.status()["recordCount"] == 2


def test_thousand_events_survive_retries(tmp_path):
    store = Store(tmp_path)
    events = []
    for index in range(1000):
        events.append(event(event_id=f"sess-1:round-{index}|0", text=f"句子{index}", session="sess-1"))
    events.append(event(event_id="sess-1:round-0|0", text="句子0修订", revision=2))
    acks = []
    for offset in range(0, len(events), 100):
        chunk = events[offset:offset + 100]
        batch = f"batch-{offset}"
        payload, digest = body_for(batch, chunk)
        acks.append(store.commit_batch(SOURCE, batch, digest, payload))
        acks.append(store.commit_batch(SOURCE, batch, digest, payload))
    assert acks[0] == acks[1]
    status = store.status()
    assert status["revisionCount"] == 1001
    assert status["recordCount"] == 1000
    assert status["lastSeq"] == 1001
    assert status["batchCount"] == 11
    view = store.db.execute("SELECT text, revision FROM records WHERE event_id=?", ("sess-1:round-0|0",)).fetchone()
    assert view["text"] == "句子0修订" and view["revision"] == 2
    manifest = json.loads((tmp_path / "manifest.json").read_text())
    assert manifest["lastSeq"] == 1001


def test_limits_schema_and_corrupt_database_keep_original(tmp_path):
    store = Store(tmp_path)
    too_big = b"{" + b"x" * (512 * 1024)
    with pytest.raises(Exception) as caught:
        store.commit_batch(SOURCE, "batch-big", sha256_hex(too_big), too_big)
    assert caught.value.status == 413
    naive = event()
    naive["receivedAt"] = "2026-10-09T12:00:00"
    naive["updatedAt"] = naive["receivedAt"]
    payload, digest = body_for("batch-naive", [naive])
    with pytest.raises(Exception) as caught:
        store.commit_batch(SOURCE, "batch-naive", "0" * 64, payload)
    assert caught.value.code == "payload_hash_mismatch"
    assert list((tmp_path / "inbox").rglob("*.jsonl")) == []
    good, good_digest = body_for("batch-keep", [event(text="必须留下")])
    store.commit_batch(SOURCE, "batch-keep", good_digest, good)
    kept = tmp_path / "inbox" / SOURCE / "batch-keep.jsonl"
    store.close()
    db = tmp_path / "state" / "receiver.sqlite"
    db.write_bytes(b"not a database")
    with pytest.raises(sqlite3.DatabaseError):
        Store(tmp_path)
    assert kept.read_bytes() == good


def test_cli_init_pair_revoke_and_refuses_public_bind(tmp_path, capsys):
    root = tmp_path / "archive"
    main(["init", "--root", str(root)])
    main(["--root", str(root), "status"])
    token_file = tmp_path / "token"
    main(["--root", str(root), "pair", "--source-id", SOURCE, "--out", str(token_file)])
    printed = capsys.readouterr().out
    token = token_file.read_text().strip()
    assert token not in printed and token.startswith("ms_")
    assert (token_file.stat().st_mode & 0o777) == 0o600
    main(["--root", str(root), "revoke", "--token-file", str(token_file)])
    store = Store(root)
    with pytest.raises(Exception) as caught:
        store.authenticate(token)
    assert caught.value.status == 401
    store.close()
    with pytest.raises(SystemExit, match="refusing_public_bind"):
        main(["--root", str(root), "serve", "--host", "0.0.0.0"])


def test_unknown_receipt_route_is_not_an_acknowledgement(tmp_path):
    client = TestClient(create_app(Store(tmp_path)))
    missing = client.get("/v1/memory/receipts/batch-1")
    assert missing.status_code == 404


def _headers(token, digest, batch, source=SOURCE):
    return {
        "Authorization": f"Bearer {token}",
        "X-Memory-Batch-Id": batch,
        "X-Memory-Payload-Hash": digest,
        "X-Memory-Source-Id": source,
    }


def client_status(store: Store) -> dict:
    return store.status()


def test_fixture_file_matches_encoder():
    fixture = Path(__file__).resolve().parents[2] / "official-addon" / "memory-sync" / "testdata" / "batch-one.jsonl"
    if not fixture.exists():
        pytest.skip("fixture is written after the encoder is stable")
    body = fixture.read_bytes()
    digest = (fixture.parent / "batch-one.sha256").read_text().strip()
    assert sha256_hex(body) == digest
    parsed_source = "glasses-demo"
    from memory_sync.protocol import parse_batch
    events = parse_batch(body, parsed_source, "batch-demo", digest)
    assert events[0]["text"] == "合成测试句子" and events[0]["sessionId"] == "sess-demo"
