# UX-6: Consolidate Logging

blocked_by: []
unlocks: [UX-9]

## Problem

Two parallel logging systems that don't talk to each other:

1. `Logging.hs` — colored `logStep`/`logSuccess`/`logInfo`/`logDebug` (mostly unused)
2. Raw `putStrLn` with manual `[*]`/`[+]`/`[!]` sigils scattered across Pipeline.hs, Cache.hs, Discover.hs, Process.hs

`logInfo` and `logDebug` from `Logging.hs` are never called. The debug flag is threaded manually via `when debug $ putStrLn`.

## Scope

### 1. Thread debug flag through Logging.hs
Add a `LogConfig` or just pass `Bool` to a `logDebug` that respects it:

```haskell
logDebug :: Bool -> Text -> IO ()
logDebug enabled msg = when enabled $ do ...
```

(This signature already exists but is unused.)

### 2. Replace all raw putStrLn logging
Find every `putStrLn` / `when debug $ putStrLn` in Pipeline.hs, Cache.hs, Discover.hs, Process.hs and replace with the appropriate `Logging.hs` function.

### 3. Remove dead code
If `logInfo` remains unused after consolidation, remove it.

## Acceptance Criteria

- Zero raw `putStrLn` for user-facing output (only in debug paths if needed)
- All logging goes through `Logging.hs` functions
- `--debug` output uses colored `[debug]` prefix consistently
- Normal output uses colored `==>`, `[+]`, `[!]` prefixes
