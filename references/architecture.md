# Architecture

InfinityContext has one portable core and no hidden execution path.

## Core (this package)

```
session transcript (JSONL)
        │
        ├─ 1. redact        session_to_sqlite.py  (fail-closed: nothing is stored if this step fails)
        ├─ 2. truncate      MAX_ARCHIVE_LENGTH    (head + tail kept, middle discarded)
        └─ 3. store         SQLite + FTS5 trigram (session_chunks → chunk_fts trigger)
                │
                └─ 4. retrieve   search.py  (read-only FTS5 with LIKE fallback)
                    5. prune     cleanup.py (retention, canonical path anchoring, VACUUM)
                    6. protect   secure_fs.py (owner-only directory, database and WAL sidecars)
```

### Why an archive instead of a bigger window

A 128K window is consumed by one deep reply: system prompt + tools (~30K), summary
(~7K), recent turns (15K) and a worst-case answer (55K) already exceed it. Compression
keeps the *working* context small; the archive keeps the *history* exact. When a detail
from an earlier turn matters, the agent queries the archive instead of replaying it.

### Data model

| Table | Purpose |
|-------|---------|
| `session_chunks` | one row per conversation chunk: `session_key`, `start_msg_id`, `end_msg_id`, `summary`, `keywords`, `anchor_questions`, `raw_content`, `created_at` |
| `chunk_fts` | FTS5 (trigram) mirror of the searchable columns, kept in sync by an `AFTER INSERT` trigger |
| indexes | `idx_session_key`, `idx_created_at`, `idx_chunk_unique (session_key, start_msg_id, end_msg_id)` |

`INSERT OR IGNORE` plus the unique index makes re-importing the same transcript
idempotent, so a host can safely re-run the archiver.

### Redaction and minimisation

Redaction runs **before** any derived field (keywords, anchors, summary) is computed, and
again on each text column immediately before insert. The rule set covers API keys,
bearer tokens, passwords, JWTs, AWS/Google/Slack credentials, PEM private keys,
connection strings, cookies, webhooks, phone numbers and email addresses. High-entropy
candidates are excluded from the keyword index.

The redaction path is fail-closed at every step:

| Stage | Failure behaviour |
|-------|-------------------|
| rule file (`redact_rules.json`) | malformed JSON, non-object schema, wrong field type or empty pattern aborts with `RedactionConfigError` **before any file or database is created** (exit 2) |
| regex compilation | every rule (built-in and custom) is compiled at startup; an uncompilable rule aborts the same way |
| rule application | a substitution error raises instead of `continue`-ing past the rule |
| `session_key` | sanitised before any path or filename is built; non-conforming or sensitive values become `opaque-<sha256[:16]>` |
| database write | the transcript is fully redacted in memory first, then written in one transaction; a failure rolls back and removes only a database created by that run |
| rule path override | `INFINITY_CONTEXT_REDACT_RULES` can point at an alternate rule file; a broken file aborts instead of falling back to defaults |
| in-place redaction | `--redact-file` refuses to run without `--allow-dir`, so the mutation is always scoped to a declared directory |
| output directory | a non-ASCII path that would break SQLite falls back to an ASCII directory, but the fallback is reported (`archive_dir_fallback: true`, `requested_dir`, `archive_dir`) and warned about — never silent |

The rule path can be overridden with `INFINITY_CONTEXT_REDACT_RULES`, which is also how
the regression tests exercise a broken rule file without touching the installed copy.

### Path and permission rules

`cleanup.py` canonicalises the archive directory, refuses to operate on a relative path,
only deletes whitelisted extensions, never follows or deletes a symbolic link, and does
nothing without `--apply`. `search.py` opens the database read-only
(`file:...?mode=ro`). Neither script opens a network socket or spawns a process.

### Filesystem hardening (T09)

The archive holds conversation history, so the store is owner-only by construction:

| Layer | POSIX | Windows |
|-------|-------|---------|
| archive directory | `chmod 0700` | protected DACL: current user + LOCAL SYSTEM, inheritance removed |
| database file | `0600`, created atomically with `O_CREAT\|O_EXCL\|O_NOFOLLOW` | protected DACL granting the file itself (`F`, no `(OI)(CI)`) |
| `-wal` / `-shm` | `0600` after the WAL pragma and again after the final checkpoint | inherits the protected directory DACL |

Creating the file with `O_CREAT | O_EXCL | O_NOFOLLOW` and `0600` removes both the
check-then-chmod window and the symlink race. A pre-existing archive directory owned by
another account is refused outright; a directory that is merely too permissive is
tightened; a symbolic link on the path is refused. Windows ACLs are written with
in-process Win32 security API calls (`ctypes`), not by spawning `icacls`.

The policy is **fail-closed**: if owner-only access cannot be enforced, the archiver
aborts, destroys the half-written database and sidecars, and exits with code 3. The only
opt-out is `--allow-insecure-storage`, which prints a warning and reports
`insecure_storage: true` in the JSON result.

In-place redaction writes through `tempfile.mkstemp` (kernel `O_EXCL`, 0600) in the
target directory, `fsync`s before the atomic replace, cleans the temporary file on every
failure path, and refuses symlinks and foreign-owned parent directories.
