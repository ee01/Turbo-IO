"""Operator commands for the local memory archive."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .protocol import ProtocolError
from .store import Store


def _take_root(argv: list[str]) -> tuple[Path | None, list[str]]:
    root = None
    cleaned: list[str] = []
    index = 0
    while index < len(argv):
        item = argv[index]
        if item == "--root":
            if index + 1 >= len(argv):
                raise SystemExit("root_required")
            root = Path(argv[index + 1])
            index += 2
            continue
        if item.startswith("--root="):
            root = Path(item.split("=", 1)[1])
            index += 1
            continue
        cleaned.append(item)
        index += 1
    return root, cleaned


def main(argv: list[str] | None = None) -> None:
    raw = list(sys.argv[1:] if argv is None else argv)
    root, raw = _take_root(raw)
    parser = argparse.ArgumentParser(description="Local Turbo IO memory archive receiver")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("init", help="Create the archive directories and database")
    pair = commands.add_parser("pair", help="Issue a revocable token bound to one source id")
    pair.add_argument("--source-id", required=True)
    pair.add_argument("--out", type=Path, required=True)
    commands.add_parser("status", help="Print counts and the commit cursor, never transcript text")
    revoke = commands.add_parser("revoke", help="Revoke a token from a local file")
    revoke.add_argument("--token-file", type=Path, required=True)
    commands.add_parser("export", help="Rebuild JSONL and Markdown projections from the database")
    serve = commands.add_parser("serve", help="Listen on loopback unless a specific host is given")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8765)

    args = parser.parse_args(raw)
    args.root = root or (Path.home() / "Memory" / "io-glasses")
    if args.command == "serve" and args.host in {"0.0.0.0", "::", ""}:
        raise SystemExit("refusing_public_bind")
    store = Store(args.root)
    try:
        if args.command == "init":
            print(json.dumps({"root": str(args.root), **_public_status(store)}, ensure_ascii=False))
        elif args.command == "pair":
            token = store.pair(args.source_id)
            _write_new(args.out, token + "\n")
            print(json.dumps({"created": str(args.out), "sourceId": args.source_id}, ensure_ascii=False))
        elif args.command == "status":
            print(json.dumps(_public_status(store), ensure_ascii=False))
        elif args.command == "revoke":
            token = args.token_file.read_text(encoding="utf-8").strip()
            print(json.dumps({"revoked": store.revoke(token)}, ensure_ascii=False))
        elif args.command == "export":
            store.rebuild()
            print(json.dumps({"exported": True, **_public_status(store)}, ensure_ascii=False))
        else:
            import uvicorn
            from .api import create_app
            uvicorn.run(create_app(store), host=args.host, port=args.port, access_log=False, log_level="info")
    except ProtocolError as exc:
        print(exc.code, file=sys.stderr)
        raise SystemExit(exc.status and 1) from exc
    finally:
        if args.command != "serve":
            store.close()


def _public_status(store: Store) -> dict:
    status = store.status()
    status.pop("service", None)
    return status


def _write_new(path: Path, text: str) -> None:
    import os
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(text)
