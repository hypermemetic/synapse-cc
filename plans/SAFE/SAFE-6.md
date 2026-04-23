---
id: SAFE-6
title: "synapse-cc warns on cookie auth mismatch"
status: Pending
type: implementation
blocked_by: [REQ-6, SAFE-7]
unlocks: []
severity: Medium
---

## Problem

After plexus-transport's cookie-only WebSocket auth migration, generated TS clients that use URL-token fallback fail silently on upgrade against any current auth-requiring backend. synapse-cc has no awareness of whether a backend requires auth, so it can't warn during build that the configured client transport is mismatched.

The result: a developer regenerates their client against a current backend, the build succeeds, the deployed client refuses every authenticated request, and the failure mode is invisible until runtime.

## Corrected detection logic (Apr 23 2026)

The original SAFE-6 draft assumed cookie auth would surface in the backend's `PluginSchema.psRequest` as a required `access_token` cookie field. That abstraction is wrong — real backends (verified against uscis / FormVeritasV2) handle cookie auth in the WS upgrade middleware (`CombinedAuthMiddleware`), not in the `PlexusRequest` struct. `PlexusRequest` models *additional* extractors layered on top of auth (origin allowlist, TLS check, etc.), never the auth cookie itself.

The correct signal for "this backend requires cookie auth" is: **any method in the IR has a param with `x-plexus-source.from == "auth"`**. That annotation comes from `#[from_auth(resolver)]` on a method parameter and is emitted by REQ-6.

## Context

- REQ-6 (plexus-macros) emits `x-plexus-source` per method param, including `from: "auth"` for `#[from_auth]` params.
- SAFE-7 (hub-codegen) generates a cookie-capable TS transport with the `SAFE-7-cookie-auth-marker` comment.
- synapse-cc orchestrates codegen but currently doesn't compare the two.

## Required behavior

| Inputs | Behavior |
|---|---|
| Backend IR has ≥1 method with `x-plexus-source.from == "auth"` AND target's existing `transport.ts` lacks the `SAFE-7-cookie-auth-marker` string | Build succeeds; emit a warning to stderr containing the substrings `cookie auth` and the target name |
| Backend IR has ≥1 auth method AND target's `transport.ts` contains the marker | No warning |
| Backend IR has zero auth methods | No warning regardless of target transport.ts contents |
| First build (target dir has no prior `transport.ts`) | No warning — nothing to mismatch |
| Target configured with a custom (non-hub-codegen) transport | Inspection finds neither marker nor URL-token construction; skip warning to avoid false positives |

Detection algorithm:

1. Read the target's IR (already available in `runPipeline`)
2. Iterate over `irMethods`; for each method, inspect its params; short-circuit to "needs cookie auth" on the first `x-plexus-source.from == "auth"` found
3. If needs-cookie-auth, check for an existing `transport.ts` in the target output dir
4. Grep for the `SAFE-7-cookie-auth-marker` string
5. If auth-required AND file exists AND no marker: emit warning

## What must NOT change

- Build still succeeds on mismatch — this is a warning, not a hard failure
- No new flags introduced; the warning fires once per build, no opt-out
- Backends with no auth methods are unaffected
- Targets configured with a custom transport (lacking the marker by design) get no warning
- Cache semantics: the warning doesn't affect cache invalidation

## Risks

1. **Marker-based detection is fragile.** If a user hand-edits the generated `transport.ts` in a way that removes the SAFE-7 marker, the warning won't fire. Acceptable trade-off — the alternative (parsing TS) is heavyweight for a defensive warning. Document the marker convention in SAFE-7 (already done).

2. **First build has no prior client to inspect.** Skip the warning; not actionable until a client exists. Subsequent builds catch the mismatch.

3. **False negatives from non-hub-codegen transports.** A user with a hand-rolled transport that happens to be cookie-capable but lacks the marker gets a false-positive warning. Mitigation: the warning wording should say "target's transport doesn't look like a SAFE-7-era hub-codegen output" rather than "your transport is broken."

## Acceptance criteria

1. Build against a backend whose IR has ≥1 method with `x-plexus-source.from == "auth"`, where the target dir contains a `transport.ts` that lacks the SAFE-7 marker: stderr contains the substrings `cookie auth` and the target name.
2. Build against the same backend with a target dir containing a SAFE-7-marked `transport.ts`: no such warning in stderr.
3. Build against a backend with no auth methods: no warning in stderr regardless of target transport.ts contents.
4. First build (no prior target/transport.ts present): no warning in stderr.
5. Build with `--force`: warning behavior unchanged from non-force builds.
6. Against uscis (after REQ-6 lands): the warning fires on first build with a stale URL-token client, is silent after regenerating with the current SAFE-7 hub-codegen.

## Coordination

- `blocked_by: [REQ-6, SAFE-7]`
- Reads `x-plexus-source` annotations emitted by REQ-6
- Reads SAFE-7's marker string. The exact marker is `SAFE-7-cookie-auth-marker` (per the landed SAFE-7 implementation).

## Completion

Implementor adds the detection in `SynapseCC.Pipeline` (or a new `SynapseCC.Auth` helper), exercises criteria 1-4 against uscis, commits. Flips status to Complete.
