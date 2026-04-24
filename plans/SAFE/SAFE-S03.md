---
id: SAFE-S03
title: "Deduplicate resolveToken between synapse and synapse-cc"
status: Complete
type: implementation
blocked_by: []
unlocks: []
severity: Low
---

> **Implementation vehicle: SELF-3 + SELF-6** (in `synapse/plans/SELF/`). The SELF epic introduces a general defaults store (`Synapse.Self`) that subsumes the per-backend token file. SELF-3 removes the `~/.plexus/tokens/<backend>` path; SELF-6 deletes `SynapseCC.Auth.resolveToken` in favor of importing `Synapse.Self`. This ticket auto-closes when both land.
>
> **Status (2026-04-24): SELF-3 landed; remaining dedup completes with SELF-6.** The legacy `~/.plexus/tokens/<backend>` path is now auto-migrated to `~/.plexus/<backend>/defaults.json` on first `Synapse.Self.loadDefaults` call (migration target is `literal:<jwt>` deliberately; keychain upgrade is an opt-in `_self` verb). `SynapseCC.Auth.resolveToken` no longer reads the legacy path — its final fallback delegates to `Synapse.Self.loadDefaults` + `defaultRegistry`. SELF-6 will collapse the module into a thin re-export of `Synapse.Self.resolveToken` and delete the synapse-cc-local mirror.

> Note: the premise that `resolveToken` lives in `synapse/app/Main.hs` and is un-importable is addressed by SELF moving the canonical implementation into the `plexus-synapse` library (`Synapse.Self`) which synapse-cc already depends on.


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

## Verdict (2026-04-24)

**Complete — closed by SELF-6.**

SELF-3 auto-migrated `~/.plexus/tokens/<backend>` to `~/.plexus/<backend>/defaults.json` and collapsed the synapse-cc token reader's legacy path onto `Synapse.Self.loadDefaults`. SELF-6 finished the job: the shared library now exposes `Synapse.Self.resolveToken` (sugar over `loadDefaults` + `defaultRegistry` + `resolveRef`), and `SynapseCC.Auth.resolveToken` is reduced to an Options-aware priority chain whose final fallback is a one-line delegation to `Self.resolveToken`. The synapse executable keeps its own loud `buildEnv` path for the same helper.

Why option (b) (thin wrapper) instead of outright deletion: `SynapseCC.Auth.resolveToken` takes a synapse-cc-local `Options` record and implements the CLI-priority chain (`--token` > `SYNAPSE_TOKEN` > `--token-file` > defaults-store). The Options-dependent chain is CLI surface, not library logic; keeping it in synapse-cc lets the library-visible fallback (step 4) live in one place without dragging `Options` into the library.

Grep enforcement passes:
- `git grep 'plexus/tokens' -- src/ app/` → no hits in synapse-cc source
- `git grep 'resolveToken' -- src/ app/` → `Auth.resolveToken` (the Options wrapper) and call sites only; no independent resolver chains

Behavior parity verified:
- `HOME=/tmp/self6smoke synapse-cc _self testbk set cookie access_token "literal:<jwt>"` then `HOME=/tmp/self6smoke synapse _self testbk show` renders the same JWT summary from the same `defaults.json`.
- Unit dedup: `SELF-6 resolveToken dedup` tests in `synapse-cc/test/Main.hs` pin `Auth.resolveToken` (no CLI flags) ≡ `Self.resolveToken` for the same HOME.

Tests: plexus-synapse:self-test 111/111 green; synapse-cc-test baseline 12 pre-existing failures unchanged, 7 new SELF-6 tests added (all green).
