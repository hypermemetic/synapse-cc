# UX-1: synapse-cc UX Overhaul — Epic Overview

## Goal

Make `synapse-cc typescript substrate` work out of the box with clear, informative output at every stage. Fix broken defaults, remove dead features, consolidate logging, and make the tool feel polished.

## Dependency DAG

```
UX-2 (fix defaults)  ──────────────────┐
UX-3 (progress output) ────────────────┤
UX-4 (ir.json location) ───────────────┼──→ UX-9 (update tests + CLAUDE.md)
UX-5 (CLI flags cleanup) ──────────────┤
UX-6 (consolidate logging) ────────────┤
UX-7 (discovery portability) ──────────┤
UX-8 (error enrichment) ───────────────┘
UX-10 (cache correctness) ─────────────→ (independent, can land anytime)
```

## Phases

### Phase 1 — Unbreak defaults (UX-2)
Make `cabal run -- synapse-cc typescript substrate` succeed without needing `--no-build --no-tests`. This is the most important fix.

### Phase 2 — Visible pipeline (UX-3, UX-6)
Users should see what's happening. Consolidate the two logging systems and add step-by-step output for normal (non-debug) runs.

### Phase 3 — CLI polish (UX-4, UX-5, UX-7, UX-8)
Fix flag ergonomics, move ir.json out of output dir, make discovery work on macOS, enrich error messages.

### Phase 4 — Wrap up (UX-9, UX-10)
Update tests, docs, and fix cache hit behavior.
