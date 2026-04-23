---
id: SAFE-S03
title: "Deduplicate resolveToken between synapse and synapse-cc"
status: Pending
type: implementation
blocked_by: []
unlocks: []
severity: Low
---

## Problem

SAFE-2 mirrors synapse's `resolveToken` function inside synapse-cc because synapse keeps `resolveToken` in `app/Main.hs` (executable scope) rather than `src/` (library scope), making it un-importable. The result is two near-identical copies of the priority chain (`--token > env > --token-file > ~/.plexus/tokens/<backend>`).

Once REQ-5 lands (which extends synapse's resolver to add `SYNAPSE_TOKEN` and `SYNAPSE_COOKIE_ACCESS_TOKEN` env vars), the two copies will further diverge unless this is deduplicated.

## Required behavior

Move `resolveToken` (and any helpers it uses) from `synapse/app/Main.hs` into a new module at `synapse/src/Synapse/Auth.hs` (or similar). Re-export from the synapse library. synapse-cc replaces its mirrored copy with `import qualified Synapse.Auth as Auth; Auth.resolveToken`.

| Inputs | Behavior |
|---|---|
| `synapse --token X backend method` | Unchanged — synapse calls its own `Auth.resolveToken` |
| `synapse-cc build typescript backend --token X` | Calls the same `Auth.resolveToken`; same priority chain |
| Both tools see the same env vars and file paths | Identical resolution outcome |

## What must NOT change

- The CLI flags exposed by either tool
- The priority chain (modulo what REQ-5 adds — that's a separate ticket)
- Behavior for users who interact with only one of the two tools

## Acceptance criteria

1. `synapse/src/Synapse/Auth.hs` exists and exports `resolveToken`
2. `synapse-cc/src/SynapseCC/*.hs` no longer contains a local `resolveToken` definition
3. Running `synapse --token X` and `synapse-cc build --token X` against the same backend with the same env both authenticate identically (verified by ensuring both produce a non-zero JWT in the request)
4. The shared module is covered by tests that pin the priority chain

## Completion

Lands after both SAFE-2 and REQ-5 are Complete (so the priority chain is stable). Implementor moves the function, updates both call sites, runs both tools' test suites.
