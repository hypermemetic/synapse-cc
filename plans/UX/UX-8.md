# UX-8: Enrich Error Messages

blocked_by: []
unlocks: [UX-9]

## Problem

1. When `tsc` or `npm test` fails, the full raw stderr (including stack traces) is dumped. Users see 15 lines of noise instead of the actual error.
2. Debug mode truncates stdout at 1000 chars, so IR JSON always shows `<large output, 187055 chars, truncated>` — useless for debugging.
3. `InvalidIR` dumps raw aeson parse errors which are unreadable.

## Scope

### 1. Summarize subprocess errors
For `LanguageToolError`, extract the first meaningful line from stderr instead of dumping everything. Show full output only in `--debug`.

### 2. Fix debug truncation
For IR generation specifically, show a summary instead of truncated raw JSON:
```
[debug] IR generated: 187055 chars, 12 plugins
```

For other commands, raise the truncation threshold to 5000 chars or show head+tail.

### 3. Improve InvalidIR messages
Wrap aeson errors with context:
```
[!] Error: Failed to parse IR output from synapse

  The IR JSON was not in the expected format.
  This usually means synapse and synapse-cc are out of sync.

  Detail: key "irPlugins" not found
```

## Acceptance Criteria

- `tsc` failure shows the actual TypeScript error, not the full stack trace
- `npm test` failure shows the test assertion, not the Node.js internals
- Debug mode shows useful IR summary instead of `<truncated>`
- `InvalidIR` errors suggest what to do
