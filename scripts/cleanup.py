#!/usr/bin/env python3
"""Prune the InfinityContext archive and reclaim disk space.

Portable core: standard library only, no shell commands, no network access.

Safety rules (deny by default):
  * the archive directory is canonicalised; every candidate must live inside it
  * only whitelisted file extensions are considered
  * symbolic links are never followed or deleted
  * nothing is removed unless ``--apply`` is given (dry-run by default)

Usage:
    python cleanup.py --dry-run
    python cleanup.py --apply --days 30
    python cleanup.py --apply --archive-dir ~/.dsh/infinity-context/archive
"""
from __future__ import annotations

import argparse
import os
import sqlite3
import sys
import time
from pathlib import Path

DEFAULT_HOME = Path(os.environ.get("INFINITY_CONTEXT_HOME") or (Path.home() / ".infinity-context"))
DEFAULT_ARCHIVE = DEFAULT_HOME / "archive"

# Only these are ever deleted. SQLite -wal/-shm files are left to SQLite itself.
ALLOWED_SUFFIXES = (".db", ".jsonl", ".bak", ".tmp", ".json")


def resolve_archive(raw: str) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        raise SystemExit(f"SECURITY: archive path must be absolute: {path}")
    return path.resolve()


def is_inside(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def vacuum(db_path: Path) -> bool:
    try:
        conn = sqlite3.connect(str(db_path))
        conn.execute("VACUUM")
        conn.close()
        return True
    except Exception as exc:  # noqa: BLE001 - report, never abort the run
        print(f"  VACUUM_SKIP {db_path.name}: {exc}", file=sys.stderr)
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Prune the InfinityContext archive")
    parser.add_argument("--archive-dir", default=str(DEFAULT_ARCHIVE),
                        help=f"archive directory (default: {DEFAULT_ARCHIVE})")
    parser.add_argument("--days", type=int, default=30,
                        help="retention in days, 1..3650 (default: 30)")
    parser.add_argument("--apply", action="store_true",
                        help="actually delete; without it the run is a dry-run")
    args = parser.parse_args()

    if not 1 <= args.days <= 3650:
        raise SystemExit(f"SECURITY: --days must be 1..3650, got {args.days}")

    archive = resolve_archive(args.archive_dir)
    if not archive.is_dir():
        print(f"ARCHIVE_MISSING: {archive}")
        return 0

    cutoff = time.time() - args.days * 86400
    deleted = 0
    skipped = 0
    reclaimed = 0

    for entry in sorted(archive.rglob("*")):
        if entry.is_symlink() or not entry.is_file():
            skipped += 1
            continue
        if not is_inside(entry.resolve(), archive):
            print(f"  SECURITY_SKIP (escapes archive): {entry}")
            skipped += 1
            continue
        if entry.suffix.lower() not in ALLOWED_SUFFIXES:
            skipped += 1
            continue
        if entry.stat().st_mtime >= cutoff:
            continue
        size = entry.stat().st_size
        if args.apply:
            try:
                entry.unlink()
            except OSError as exc:
                print(f"  DELETE_FAIL {entry.name}: {exc}", file=sys.stderr)
                continue
            deleted += 1
            reclaimed += size
            print(f"  DELETED {entry.name} ({size} bytes)")
        else:
            deleted += 1
            reclaimed += size
            print(f"  WOULD DELETE {entry.name} ({size} bytes)")

    vacuumed = 0
    for db in sorted(archive.rglob("*.db")):
        if db.is_symlink() or not db.is_file():
            continue
        if args.apply:
            if vacuum(db):
                vacuumed += 1

    mode = "APPLIED" if args.apply else "DRY-RUN"
    print(f"CLEANUP {mode}: candidates={deleted} skipped={skipped} "
          f"reclaimed={reclaimed} bytes vacuumed={vacuumed} archive={archive}")
    if not args.apply:
        print("(nothing was deleted - re-run with --apply)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
