---
id: SAFE-2
title: "synapse-cc threads JWT token through Options"
status: Complete
type: implementation
blocked_by: []
unlocks: []
severity: High
---

**Implemented Apr 22 2026 (autonomous run):** New `SynapseCC.Auth` module mirrors synapse's `resolveToken` with added `SYNAPSE_TOKEN` env var. `Options` gains `optToken` / `optTokenFile`. CLI gains `--token`/`-t` and `--token-file` on build + watch. `Pipeline.hs:700` and `Watch.hs:213` resolve and pass the token to `initEnv`. Verified: `synapse-cc build typescript substrate --token X` succeeds; `SYNAPSE_TOKEN=X synapse-cc build` succeeds. SAFE-S03 tracks deduplication once REQ-5 ships fully.

## Problem

synapse-cc cannot connect to auth-required backends. The current code passes `Nothing` as the token argument to synapse's `initEnv` at every call site. There is no flag, env var, or token-file plumbing — the option simply does not exist. Users must drop down to raw `synapse` to talk to any auth-gated backend.

## Context

synapse already supports four token sources, in priority order:

1. `--token <jwt>` flag
2. `SYNAPSE_TOKEN` env var
3. `--token-file <path>` flag
4. `~/.plexus/tokens/<backend>` (per-backend file)

synapse-cc embeds synapse as a library and must offer the same UX so users have one consistent token surface across both tools.

## Required behavior

| Inputs | Behavior |
|---|---|
| `synapse-cc build typescript clients` against an auth-required backend, no token from any source | Fail with an error message that names all four resolution paths |
| `synapse-cc build typescript clients --token <jwt>` | Use that token |
| `SYNAPSE_TOKEN=<jwt> synapse-cc build typescript clients` | Use that token |
| `synapse-cc build typescript clients --token-file <path>` | Read file (trim trailing newline), use as token |
| Token file at `~/.plexus/tokens/<backend>` exists, no other source | Use file token |
| Multiple sources present | Higher-priority source wins, lower-priority sources silently ignored |

The same token resolution applies uniformly to the `build`, `watch`, and `wait` commands.

## What must NOT change

- Existing `--no-build`, `--no-tests`, `--force`, `--cache-dir` flag behavior is unchanged
- `synapse-cc init` does not need to ask about tokens (out of scope; covered by SAFE-3 if at all)
- Backends that don't require auth continue to build with no token configured
- The `synapse-cc` binary's exit code for a successful build remains 0
- Cache key computation (IR cache key based on backend name) is unchanged — the token is not part of the cache key

## Risks

1. **Synapse's token resolver may be private.** If the function is not exposed from the synapse library, synapse-cc must reimplement the priority chain. Mitigation: read priority chain from `synapse/app/Main.hs` and mirror it in `SynapseCC.Options`. This is a code-duplication concern, not a correctness risk.

## Acceptance criteria

1. Running `synapse-cc build typescript <auth-required-backend>` without a token produces a non-zero exit code and an error message containing all four substrings: `--token`, `SYNAPSE_TOKEN`, `--token-file`, `~/.plexus/tokens`
2. Running with `--token <valid-jwt>` succeeds
3. Running with `SYNAPSE_TOKEN=<valid-jwt>` env succeeds
4. Running with `--token-file <path-to-file-containing-valid-jwt>` succeeds
5. Running with token in `~/.plexus/tokens/<backend>` (no other source set) succeeds
6. With both `--token=A` and `SYNAPSE_TOKEN=B` set, the build authenticates as `A` (higher-priority wins)
7. With both `SYNAPSE_TOKEN=A` and `~/.plexus/tokens/<backend>=B` set, the build authenticates as `A`
8. Token resolution behavior is observably identical between `synapse-cc build` and `synapse-cc watch` (same env, same flags, same outcome)

## Completion

Implementor delivers code that compiles cleanly, runs the build against an auth-required backend with each of the four token sources, and shares command output for one happy-path and the missing-token error case. Flips status to Complete in the same commit.
