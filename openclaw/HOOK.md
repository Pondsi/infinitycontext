---
name: compaction-pipeline
description: "Run full backup/SQLite/enhanced-summary pipeline around every compaction (manual, auto, or watchdog)."
metadata:
  {
    "openclaw":
      {
        "emoji": "🗄️",
        "events": ["session:compact:before", "session:compact:after"],
        "always": true,
      },
  }
---

# Compaction Pipeline Hook

Runs the full InfinityContext pipeline (trajectory backup → SQLite conversion → enhanced summary) around every compaction event, regardless of who triggers it:

- **Manual compact** (user clicks in UI)
- **Built-in auto-compact** (49% threshold or keepRecentTokens safeguard)
- **Watchdog-triggered compact** (main-session-monitor.ps1)

## What It Does

### Before compaction (`session:compact:before`)
1. Exports full trajectory via `openclaw sessions export-trajectory`
2. Converts trajectory JSONL to SQLite with FTS5 trigram index
3. Preserves the complete conversation history before it's summarized

### After compaction (`session:compact:after`)
1. Runs enhanced summary generation on the SQLite database
2. Generates keyword-enriched summaries for long-range retrieval
3. Logs pipeline completion status

## Configuration

Enable in `openclaw.json`:

```json
{
  "hooks": {
    "internal": {
      "entries": {
        "compaction-pipeline": {
          "enabled": true
        }
      },
      "load": {
        "extraDirs": ["~/.openclaw/hooks"]
      }
    }
  }
}
```

## How It Works

The hook calls existing pipeline scripts:
- `~/.openclaw/scripts/main-session-monitor.ps1` (Invoke-Compact function for backup + SQLite)
- `~/.openclaw/scripts/session-to-sqlite.ps1` (JSONL → SQLite conversion)

Each step runs as a detached background process to avoid blocking the OpenClaw runtime.
