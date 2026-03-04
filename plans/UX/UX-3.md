# UX-3: Add Progress Output for Normal Runs

blocked_by: []
unlocks: [UX-9]

## Problem

Between "Connecting to substrate..." and "Client ready at ./generated", there is zero output unless `--debug` is set. The pipeline takes 5+ seconds and the user sees a frozen terminal.

## Scope

Add one-liner step announcements for each pipeline phase in normal (non-debug) mode:

```
==> Discovering tools...
[+] Found all required tools

==> Connecting to substrate at 127.0.0.1:4444...
==> Generating IR...
[+] IR generated (12 plugins)
==> Generating code...
[+] 80 files generated (1 updated, 79 unchanged)
==> Installing dependencies...
[+] Dependencies installed (pnpm)

[+] Client ready at ./generated
```

### Implementation

In `Pipeline.hs`, add `logStep` / `logSuccess` calls at each stage boundary. Parse summary info from tool stdout where possible (hub-codegen already prints merge summary).

## Acceptance Criteria

- Each pipeline step prints a visible one-liner before and after
- No output duplication with `--debug` (debug adds detail, normal shows summary)
- Timing info not required (keep it simple)
