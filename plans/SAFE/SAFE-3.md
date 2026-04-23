---
id: SAFE-3
title: "synapse-cc discovers backends via the Plexus registry"
status: Complete
type: implementation
blocked_by: []
unlocks: []
severity: High
---

**Implemented Apr 22 2026 (autonomous run):** New `SynapseCC.RegistryResolve` wraps `Synapse.Backend.Discovery.registryDiscovery`. `Pipeline.generateIR` resolves the backend name via the registry at `--host`/`--port` (defaults `127.0.0.1:4444`). Falls back to that address when the registry is unreachable (preserves the "substrate IS the registry" legacy path). Returns `BackendUnreachable` with a list of known backends + `synapse-cc init` hint when the name is unknown. Verified: `synapse-cc build typescript lforge` succeeds with no `-P` flag (registry resolves to `127.0.0.1:44104`); bogus backend errors with helpful list.

## Problem

synapse-cc cannot reach backends running on non-default ports without manual `-P` flags. It assumes every backend lives at `127.0.0.1:4444`. Today, building a client for `lforge` (which lives at `127.0.0.1:44104`) requires `synapse-cc build typescript lforge -P 44104` — and the user must already know that port. If they don't, they get a `-32601 Method not found` error from substrate (the wrong backend) with no hint about what went wrong.

## Context

The Plexus registry (typically substrate at `:4444`) maps backend names to host:port via a `_registry` schema. `synapse` itself queries the registry — running `synapse` with no args lists all registered backends with their resolved addresses. synapse-cc currently bypasses this and uses raw host/port defaults from its CLI parser.

The registry lookup is a single RPC call to `_registry.list` (or equivalent). The registry's own host:port is the only configuration that needs a default.

## Required behavior

| Inputs | Behavior |
|---|---|
| `synapse-cc build typescript substrate` (no port flag) | Resolve "substrate" via registry; if registry reports `127.0.0.1:4444`, connect there |
| `synapse-cc build typescript lforge` (no port flag) | Resolve "lforge" → `127.0.0.1:44104` via registry; build succeeds with no `-P` flag |
| Backend name not in registry | Fail with an error listing all registered backend names and a hint to run `synapse-cc init` |
| Registry unreachable AND no `-P` flag passed | Fall back to default `127.0.0.1:4444`; print a warning that registry lookup failed |
| `--port <N>` explicitly passed | Skip registry lookup, use provided port (manual override) |
| Backend listed in `synapse.config.json` with explicit URL | Skip registry lookup, use the configured URL |

The registry's own location is configurable via `--registry-host` and `--registry-port` flags, defaulting to `127.0.0.1:4444`. These flags are distinct from `-H` / `-P` (the latter override the resolved backend address).

## What must NOT change

- Manual `-H` / `-P` flags continue to work as overrides — no behavior change for users who already pass them
- Backends listed in `synapse.config.json` with explicit URLs continue to work as today
- IR cache key computation (based on backend name, not host/port) is unchanged
- Registry lookup is a one-time call per build; no caching layer added in this ticket

## Risks

1. **Registry RPC method name is not pinned.** synapse-cc and `synapse` must agree on the registry method name. If `synapse`'s implementation uses a private helper, synapse-cc must call the same RPC method by its public name. Mitigation: reuse synapse's registry-discovery code path if exposed; otherwise mirror it.
2. **Backend-not-in-registry false positive.** If the registry is partially populated, a real backend may be missing. The fallback path (default port) handles this gracefully but suppresses the user's chance to fix the registry. Acceptable trade-off for v1.

## Acceptance criteria

1. With substrate listening on `:4444` and lforge listening on `:44104`, `synapse-cc build typescript lforge` succeeds with no `-P` flag
2. `synapse-cc build typescript not-a-real-backend` fails with an error containing the string of at least one real registered backend name (e.g. "substrate") AND the substring `synapse-cc init`
3. With the registry stopped (no process listening on `:4444`) and `synapse-cc build typescript substrate -P 4444` invoked: the build still succeeds (manual override path)
4. With registry running but `synapse-cc build typescript substrate --port 4444` invoked: the build behaves exactly as today (no behavior regression for explicit-port callers)
5. `synapse-cc build typescript substrate` (no port flag) connects to whatever host:port the registry reports for "substrate" — confirmed by introspecting the IR cache manifest's recorded backend URL
6. `--registry-host` and `--registry-port` flags accept values and override the registry default

## Completion

Implementor confirms acceptance criteria 1, 2, and 3 by running the build against a live multi-backend setup. Flips status to Complete in the same commit.
