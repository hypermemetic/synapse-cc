---
id: SAFE-S01
title: "Spike: Does plexus-core expose its version via _info or PluginSchema?"
status: Complete
type: spike
blocked_by: []
unlocks: [SAFE-4, SAFE-S02]
---

## Question

Is the plexus-core toolchain version reachable from a backend's introspection surface (`_info`, `PluginSchema`, or any other RPC the synapse client can hit)? SAFE-4 requires this to detect plexus-core major bumps and invalidate stale IR.

## Setup

Inspected three locations in plexus-core 0.5.2 source:
- `src/plexus/schema.rs` — `PluginSchema` definition + serialization
- `src/plexus/plexus.rs` — `_info` endpoint registration
- `src/mcp_bridge.rs` — alternative info endpoints

Inspected the Haskell-side `PluginSchema` in `plexus-protocol/src/Plexus/Schema/Recursive.hs` to see what synapse already decodes.

## Result: NEGATIVE

The plexus-core version is **not exposed** anywhere a synapse client can read it:

1. **`_info` endpoint** (`plexus-core/src/plexus/plexus.rs:983`) — returns the backend name as a single-item stream and nothing else. No version field, no toolchain block.
2. **`PluginSchema`** (`plexus-core/src/plexus/schema.rs:250`) — has `version: String` but that is the *plugin's* version (e.g. "1.0.0"), not the plexus-core toolchain version.
3. **`DeprecationInfo`** (`plexus-core/src/plexus/schema.rs:87-91`) — references plexus-core versions in `since` and `removed_in` fields but only per-deprecation, not as a global toolchain stamp.
4. **`mcp_bridge.rs:204-211`** — `get_info()` returns `ServerInfo` populated from `Implementation::from_build_env()` — this is MCP-server-info, not surfaced through the WS protocol.

Confirmed `Cargo.toml` reports `version = "0.5.2"` for plexus-core today, so the value exists; it just isn't published.

## Implication for SAFE-4

SAFE-4 cannot do real version-gating today. Two paths:

1. **Wait for plexus-core to expose its version** — covered by follow-up ticket `SAFE-S02`.
2. **Land SAFE-4 in degraded mode** — write the cache-manifest plumbing now (so the field is recorded as `null` or `"unknown"`); warn once at build time that version-gating is unavailable; skip cache invalidation until SAFE-S02 lands.

Path 2 is the chosen approach for the autonomous run. SAFE-4 is downgraded accordingly.

## Pass / fail

This spike was binary: is the version reachable? Answer: no. Spike is Complete with negative result. No follow-up spike needed; the implementation question (how to land SAFE-4 anyway) is answered above.
