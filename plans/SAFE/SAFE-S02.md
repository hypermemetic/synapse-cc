---
id: SAFE-S02
title: "plexus-core: expose toolchain version in _info response"
status: Pending
type: implementation
blocked_by: [SAFE-S01]
unlocks: [SAFE-4]
severity: Low
---

## Problem

plexus-core 0.5.2 does not surface its own toolchain version through any RPC introspection endpoint. SAFE-S01 confirmed this: `_info` returns only the backend name; `PluginSchema` carries the plugin's version but not the plexus-core toolchain version.

Without this, downstream tooling (synapse, synapse-cc, hub-codegen) cannot detect plexus-core major bumps and cannot invalidate stale IR or refuse incompatible builds.

## Required behavior

The `_info` endpoint extends its single-item response to include a structured object:

| Field | Type | Source |
|---|---|---|
| `name` | string | backend's runtime namespace (current behavior) |
| `plexus_core_version` | string | `env!("CARGO_PKG_VERSION")` from plexus-core itself, evaluated at compile time |

Existing clients that only read `name` continue to work — the new field is additive.

## What must NOT change

- The `_info` notification method name (`PLEXUS_NOTIF_METHOD`) is unchanged
- The stream-item shape is unchanged in fundamentals — only the payload object gains a field
- Backends not built with the new plexus-core continue to work; downstream consumers must treat the field as optional

## Acceptance criteria

1. After this ticket lands, calling `synapse <backend> _info` against any backend built with the new plexus-core returns JSON containing both `name` and `plexus_core_version`
2. `plexus_core_version` value matches `env!("CARGO_PKG_VERSION")` at backend build time
3. Backends built with older plexus-core continue to respond to `_info` without error (no schema validation against the new field)
4. The synapse-cc IR cache manifest, after rebuilding against a new-plexus-core backend, contains a non-empty `toolchain.plexus_core_version` (this validates the SAFE-4 integration end-to-end)

## Coordination

- Lives outside the SAFE epic technically (it's a plexus-core change), but is tracked here because it directly unblocks SAFE-4's full functionality
- SAFE-4 ships in degraded mode without this; once SAFE-S02 lands, SAFE-4's invalidation path becomes active

## Completion

Implementor adds the field to `_info`'s response object, runs an integration test where a synapse client reads back the version, and flips status to Complete.
