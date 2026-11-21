---
name: memory-flush-dedup
description: "Deduplicate byte-identical memory sections repeatedly appended to daily memory files when compaction memoryFlush retries re-run after a failed compaction."
metadata:
  {
    "openclaw":
      {
        "emoji": "🧹",
        "events": ["session:compact:after"],
        "always": true,
      },
  }
---

# Memory Flush Dedup Hook

**Background (root cause identified 2026-09-10)**: compaction memoryFlush (agentic memory write before compaction) retries the whole operation after "flush already written to disk but the main compaction step failed". The retry appends the same content again to the daily diary (`memory/YYYY-MM-DD.md`), producing paired duplicate blocks (4 consecutive duplicates on 09-10; 14 diary files had the same issue since 08-08). This hook clears such duplicates immediately after every compaction.

## Behavior

- Trigger: `session:compact:after` (runs in-process after compaction finishes for all agents).
- Scan target: `YYYY-MM-DD*.md` diaries under `~/.openclaw/workspace*/memory/` modified within the last 24h.
- Dedup rule (conservative): split sections by `^## ` headings; two sections are duplicates only when their **non-empty line content is identical** (ignoring trailing whitespace, blank-line count, and standalone HTML comment markers). Keep only the **first copy**; delete later copies as-is. Any substantive difference is always kept (prefer false negatives over false deletes).
- Before modifying, automatically back up to `memory/.bak/<name>.<timestamp>.dedup.bak`; automatically clean `.dedup.bak` files older than 14 days.
- Log: `~/.openclaw/logs/memory-flush-dedup.log`. All exceptions are only logged, never thrown (never affect the main compaction flow).

## CLI mode (run with node directly)

```powershell
node handler.js --scan --dry-run   # full history diary dry-run, report only
node handler.js --scan             # dedupe full history diary (auto backup)
node handler.js --file <path>      # process a single file
```

## Known boundaries

- Near-duplicates across flushes (e.g. one version with a project marker and one without) are treated as the same key and the **first copy with the marker** is kept; other substantive differences are not merged.
- Only diary files are processed; MEMORY.md and the scenario library are left untouched.
