---
id: SAFE-S05
title: "[SUPERSEDED] REQ-6/REQ-7/SAFE-6 umbrella — split into concrete tickets"
status: Superseded
type: implementation
blocked_by: []
unlocks: []
superseded_by: [REQ-6, REQ-8, REQ-9, SAFE-6]
---

## Why superseded

This umbrella was written Apr 22 2026 when the plan was to defer REQ-6, REQ-7, and SAFE-6 together until a live `PlexusRequest` consumer existed. Uscis (FormVeritasV2) emerged as that consumer the same day, and follow-up analysis (Apr 23) revealed three distinct concerns that deserve their own tickets rather than a single umbrella:

- **REQ-6** (plexus-macros) — the macro-side work of emitting per-method `x-plexus-source` annotations. Rewritten with full scope including `required = [...]` field locking.
- **REQ-8** (synapse renderer) — new ticket: per-method auth and source display in `synapse <bk> <plugin>` output.
- **REQ-9** (hub-codegen) — new ticket: JSDoc emission retargeted from activation-level (tonight's minimal) to per-method. Supersedes REQ-7's JSDoc acceptance criteria.
- **SAFE-6** (synapse-cc) — rewritten with corrected detection logic (any method has `from: auth`, not cookie field in psRequest).

## Status

Tracked as reference; no action needed. All four successor tickets exist and are Pending.
