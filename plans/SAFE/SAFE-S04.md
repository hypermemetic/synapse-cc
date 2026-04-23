---
id: SAFE-S04
title: "Follow-up: complete REQ-5's CLI flags + pre-flight check + env var scanning"
status: Partial
type: implementation
blocked_by: []
unlocks: []
severity: Low
---

**Partial implementation Apr 23 2026 (autonomous run):** `--cookie KEY=VALUE`,
`--header KEY=VALUE`, `SYNAPSE_COOKIE_<KEY>` and `SYNAPSE_HEADER_<KEY>`
landed in `synapse/app/Main.hs`. Plumbed through `SynapseEnv` (new
`seCookies`/`seHeaders` fields + `withRequestContext` helper) and
`Synapse.Transport.getConfig` via `mergeUpgradeHeaders`, which builds
the WS upgrade Headers from optional token, extra cookies (single
Cookie header, semicolon-joined), and extra headers. Verified against
uscis end-to-end: cookies and headers reach the WS upgrade.

**Still deferred:**
- `--query KEY=VALUE` flag (no consumer in uscis FormVeritasRequest; out of scope tonight)
- Pre-flight `checkRequestSatisfied` warning (REQ-5 §5) — would inspect the
  IR's `irPluginRequests[namespace]` and warn when a required cookie/header
  field has no satisfying source in the env. Untestable end-to-end against
  uscis because all FormVeritasRequest fields are derived (no required
  cookie/header keys to flag).

## Problem

The autonomous Apr 22 2026 run landed the IR + renderer halves of REQ-5 in synapse:

- ✅ `psRequest :: Maybe Value` added to `Plexus.Schema.Recursive.PluginSchema`
- ✅ `irPluginRequests :: Maybe (Map Text Value)` added to `Synapse.IR.Types.IR`
- ✅ `Synapse.IR.Builder.irAlgebra` populates per-namespace request schemas
- ✅ `Synapse.Algebra.Render` emits the "Authentication required" notice and "Request requirements:" block when a backend has a `psRequest` schema

The following REQ-5 acceptance criteria were **not** implemented:

- `--cookie KEY=VALUE`, `--header KEY=VALUE`, `--query KEY=VALUE` flags on `synapse`
- `SYNAPSE_COOKIE_<KEY>` / `SYNAPSE_HEADER_<KEY>` env var scanning (`SYNAPSE_TOKEN` already works)
- Pre-flight `checkRequestSatisfied` warning (REQ-5 §5)
- Plumbing the resolved cookies/headers/query into the WebSocket upgrade

## Why deferred

No backend in the workspace currently declares `PlexusRequest`, so the IR's `psRequest` is `Nothing` for substrate, lforge, and every other live backend. Without a real consumer, the CLI flags were untestable end-to-end. The renderer was prioritized because it costs nothing for backends without `psRequest` and is the visible UI piece.

Additionally, the WebSocket upgrade plumbing in `Synapse.Transport` would need to thread cookies/headers/query through `initEnv` -> `SynapseEnv` -> `Plexus.Transport`, which is a non-trivial cross-cutting change.

## Required behavior

Implement the three deferred pieces per REQ-5 §4 and §5 verbatim:

| Inputs | Behavior |
|---|---|
| `synapse <bk> <method> --cookie session_id=abc` | Cookie attached to WS upgrade |
| `synapse <bk> <method> --header origin=https://app.dev` | Header attached to WS upgrade |
| `synapse <bk> <method> --query tenant=acme` | Query string appended to WS upgrade URI |
| `SYNAPSE_COOKIE_SESSION_ID=abc synapse <bk> <method>` | Equivalent to `--cookie session_id=abc` |
| `SYNAPSE_HEADER_ORIGIN=https://app.dev synapse <bk> <method>` | Equivalent to `--header origin=https://app.dev` |
| Pre-flight: required field missing from psRequest, no source provides it | Stderr warning naming the missing field + its source type |

## What must NOT change

- Existing `--token` / `SYNAPSE_TOKEN` / `--token-file` / `~/.plexus/tokens/<bk>` resolution (SAFE-2 path)
- Backends without `psRequest` continue to work without warnings
- The renderer changes (already landed) remain as-is

## Acceptance criteria

Carry over the remaining (unchecked) items from REQ-5's Acceptance Criteria section verbatim.

## Coordination

- Blocked by: a real backend declaring `PlexusRequest` (so the integration tests can be exercised)
- Lands in `synapse/app/Main.hs` (CLI parsing + env scanning) and `synapse/src/Synapse/Transport.hs` (upgrade plumbing)
- Once landed, mark REQ-5 Complete

## Completion

Implementor lands the three pieces; runs the integration test against a backend with `request = MyRequest`; flips REQ-5 to Complete.
