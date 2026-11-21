# L1 Model Fallback Chain (memory-tencentdb patch)

## Problem it solves

When `memory-tencentdb` runs L1 extraction / L2 scenes / L3 profile in a "clean context run",
`plugins.enabled=false` → only 8 core built-in APIs are registered. Native `ollama` is registered by a plugin →
it always fails with `No API provider registered for api: ollama`. Also, as a shared skill, other installers
have different model configs, so no specific model can be hardcoded.

## What the patch does

Patch the plugin `dist/index.mjs` in place:

| Marker | Meaning |
|---|---|
| P1 | Add `resolveModelChain()` — ordered fallback chain + api availability filtering |
| P2a | Collection side: walk raw messages of `agent_end` backwards to get the assistant's provider/model, write a sidecar file |
| P2b | Dispatch side: read the sidecar file; chain head prefers "last model used in the session" |
| P2c–e | Pass sessionModel through to `CleanContextRunner` |

Fallback chain order (first available wins, deduplicated, drop apis unavailable in clean runs):

1. Last model used in that session (P2 sidecar file)
2. That agent's default model `agents.entries[<agentId>].model.primary`
3. Global default model `agents.defaults.model.primary`
4. That agent's fallback list `agents.entries[<agentId>].model.fallbacks[]`
5. Global fallback list `agents.defaults.model.fallbacks[]`

Evidence log (info level):
- `[l0] session last-used model -> <provider>/<model>` — written by the collection side
- `[l1] session last-used model: <provider>/<model>` — read by the dispatch side
- `[l1] model chain: A/B -> C/D -> ...` — the final effective full fallback chain

## Usage

```powershell
# apply patch (auto-locate plugin dist; idempotent)
.\scripts\apply.ps1

# check only
.\scripts\apply.ps1 -Check

# restore from latest backup
.\scripts\apply.ps1 -Restore

# or pass the dist path manually
python patch_l1_model_chain.py "<openclaw-npm>/.../memory-tencentdb/dist/index.mjs"
```

After patching, run `openclaw daemon restart` (process-level restart for the ESM cache).

## Verification

Every script run: anchor must hit exactly once → backup before write → `node --check` → sha256 → idempotent skip.
