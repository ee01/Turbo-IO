"""HTTP surface. Health and ACKs never include transcript text."""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from . import PROTOCOL_VERSION, SCHEMA_VERSION
from .protocol import ProtocolError
from .store import Store

log = logging.getLogger("memory_sync")


def create_app(store: Store) -> FastAPI:
    app = FastAPI(title="memory-sync", docs_url=None, redoc_url=None, openapi_url=None)

    @app.get("/v1/memory/health")
    def health():
        return {"protocol": PROTOCOL_VERSION, "schemaVersion": SCHEMA_VERSION, "service": "memory-sync", "status": "ok"}

    @app.post("/v1/memory/batches")
    async def batches(request: Request):
        token = _bearer(request.headers.get("authorization"))
        source_header = request.headers.get("x-memory-source-id") or ""
        batch_id = request.headers.get("x-memory-batch-id") or ""
        payload_hash = request.headers.get("x-memory-payload-hash") or ""
        body = await request.body()
        try:
            bound = store.authenticate(token)
            if bound != source_header:
                raise ProtocolError("source_mismatch", 403)
            ack = store.commit_batch(source_header, batch_id, payload_hash, body)
        except ProtocolError as exc:
            log.info(
                "batch reject source=%s batch=%s status=%s code=%s bytes=%s",
                _safe_id(source_header), _safe_id(batch_id), exc.status, exc.code, len(body),
            )
            return JSONResponse({"error": exc.code}, status_code=exc.status)
        except Exception:
            log.info(
                "batch reject source=%s batch=%s status=500 code=internal bytes=%s",
                _safe_id(source_header), _safe_id(batch_id), len(body),
            )
            return JSONResponse({"error": "internal"}, status_code=500)
        log.info(
            "batch commit source=%s batch=%s status=200 events=%s bytes=%s",
            _safe_id(source_header), _safe_id(batch_id), len(ack["events"]), len(body),
        )
        return ack

    return app


def _bearer(header: str | None) -> str:
    if not header or not header.startswith("Bearer ") or len(header) > 300:
        return ""
    return header[7:]


def _safe_id(value: str) -> str:
    if len(value) > 128 or any(character.isspace() for character in value):
        return "-"
    return value
