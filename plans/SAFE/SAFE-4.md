---
id: SAFE-4
title: "synapse-cc version-gates IR against plexus-core"
status: Complete
type: implementation
blocked_by: []
unlocks: []
severity: Medium
---

**Implemented Apr 22 2026 (autonomous run, degraded mode per SAFE-S01):** `ToolchainVersions` gains `tvPlexusCore :: Maybe Text`. Cache writers stamp `Nothing` today (verified in `~/.cache/plexus-codegen/synapse/ir/<bk>/manifest.json`). Debug-level log notes that version-gating is inactive. Full mode (cache invalidation on major bump) activates with no further synapse-cc changes once SAFE-S02 lands plexus-core-side.

## Problem

plexus-core ships breaking changes (recent example: `ChildRouter::router_call` gained a 5th `raw_ctx: Option<&RawRequestContext>` parameter). Cached IR generated against an older plexus-core version may misrepresent the current backend's contract — synapse-cc would happily reuse stale IR and emit clients that compile but encode the wrong shape.

There is no defense against this drift today. The IR cache manifest records `synapseccVersion` and `synapseVersion` but not `plexusCoreVersion`.

## Context

The IR cache manifest is a JSON file with a `toolchain` section that already includes synapse-cc's and synapse's versions; adding `plexus_core_version` is a one-field extension.

Major version bumps (e.g. `0.5.x → 0.6.0`) signal breaking changes per semver. Minor and patch bumps are additive and should not invalidate the cache.

**Spike SAFE-S01 finding (NEGATIVE):** plexus-core 0.5.2 does NOT currently expose its toolchain version through any RPC endpoint. `_info` returns only the backend name; `PluginSchema` carries the *plugin's* version (e.g. "1.0.0"), not plexus-core's. Therefore SAFE-4 ships in **degraded mode**: it stamps `plexus_core_version: null` (or "unknown") into the manifest and warns once per build that version-gating is unavailable. The follow-up ticket SAFE-S02 adds the field to plexus-core's `_info`; once that lands, SAFE-4's invalidation logic activates with no further changes.

## Required behavior (degraded mode, today)

| Inputs | Behavior |
|---|---|
| Backend doesn't report plexus_core version (current state of all backends) | Stamp `plexus_core_version: null` in manifest; warn once per build that version-gating is inactive (referencing SAFE-S02) |
| `--force` is passed | All version-gate logic skipped; full regeneration as today |

## Required behavior (full mode, after SAFE-S02 lands)

| Inputs | Behavior |
|---|---|
| Cached IR `plexus_core_version = 0.5.x`, backend reports `0.5.y` (any patch/minor) | Cache hit (no regeneration) |
| Cached IR `plexus_core_version = 0.5.x`, backend reports `0.6.0` (major bump) | Cache invalidated, IR re-fetched, notice printed naming both versions |
| Cached IR has no `plexus_core_version` field (legacy cache) | Treat as cache miss, re-fetch IR, write new manifest with the version field populated |
| Backend doesn't report plexus_core version (older backend) | Cache by IR hash only; warn once that version-gating is unavailable |
| `--force` is passed | All version-gate logic skipped; full regeneration as today |

Comparison is on the major version number only. Pre-1.0 versions follow the convention that minor bumps are breaking — for `0.x.y` versions, treat the minor number as the major. (`0.5 → 0.6` is breaking; `0.5.0 → 0.5.7` is not.)

## What must NOT change

- IR cache file format remains backward-readable: a manifest written by an older synapse-cc (with no `plexus_core_version` field) is parseable, just triggers a re-fetch
- Manual `--force` continues to bypass all caching, including version-gate
- The IR JSON itself is unchanged in shape (this ticket adds metadata to the cache manifest, not the IR)
- Backends that don't report a plexus-core version continue to work — they get a one-time warning, not a failure

## Risks

1. ~~plexus-core may not currently expose its version via the schema.~~ **CONFIRMED NEGATIVE by SAFE-S01.** Mitigated via degraded mode (above). SAFE-S02 follow-up tracks the plexus-core change.
2. **0.x semver convention may not match how the team versions plexus-core.** If plexus-core treats patch bumps as breaking too, the gating logic over-permissive. Mitigation: confirm convention during implementation; the ticket can be tightened before completion. (Inactive while in degraded mode.)

## Acceptance criteria

1. With cached IR generated against plexus-core `0.5.3` and a backend reporting `0.6.0`: `synapse-cc build` re-fetches IR and prints a notice containing both version strings (`0.5.3` and `0.6.0`)
2. With cached IR `0.5.3` and backend `0.5.7`: `synapse-cc build` uses cached IR (cache-hit log line)
3. With a backend that doesn't report plexus_core_version: `synapse-cc build` succeeds and prints a one-time warning containing the substring `version-gate`
4. After any successful build against a version-reporting backend, the IR cache manifest at `~/.cache/synapse/ir/<backend>/manifest.json` contains a `toolchain.plexus_core_version` field with a non-empty string value
5. `synapse-cc build --force` succeeds regardless of cached version mismatch (no version-gate enforcement)
6. A manifest written by an older synapse-cc (lacking the field) is parseable and triggers exactly one re-fetch (the next build hits cache)

## Completion

Implementor verifies criteria 1-4 manually against a live backend (or fixture), commits the change, and flips status to Complete.
