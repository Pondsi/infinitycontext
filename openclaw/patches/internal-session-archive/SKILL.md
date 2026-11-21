# Internal Session Silencing (keep only exceptions)

## Problem it solves

Every time `memory-tencentdb` runs L1 extraction / conflict detection / L2 scene extraction / L3 profile,
it starts a separate "clean context run". The gateway registers a session node per run,
so the sidebar Other section gains an extra row. `delivery.kind=none` only means "no delivery report after the run",
**it does not mean the session is not registered**.

## Decision rules

| status | Clear unread badge | Archive | Intent |
|---|---|---|---|
| `done` (success) | ✅ clear (incidentally) | ✅ archive | Successful runs should not occupy slots |
| `running` and others | ❌ do not touch | ❌ do not archive | — |
| `failed` / `timeout` / `error` | ❌ **never touch** | ❌ **never touch** | **Exceptions must keep the red badge** |

## Usage

```powershell
python archive-internal-sessions.py --selftest    # classification self-test (4 assertions)
python archive-internal-sessions.py --status       # show current status
python archive-internal-sessions.py --dry-run      # report only
python archive-internal-sessions.py                # run
python archive-internal-sessions.py --loop 55 --interval 5  # loop mode
```

## Scheduled task

`.\install-task.ps1` registers `OpenClaw-InternalSessionArchive`,
starting a 55-second loop every 1 minute (Task Scheduler minimum repeat interval is 1 minute).
