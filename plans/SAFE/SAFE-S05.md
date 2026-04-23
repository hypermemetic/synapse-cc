---
id: SAFE-S05
title: "Follow-up: REQ-6, REQ-7, SAFE-6 — blocked on a live PlexusRequest consumer"
status: Pending
type: implementation
blocked_by: []
unlocks: []
severity: Low
---

## Problem

Three tickets in the SAFE/REQ epic are designed and ready but cannot be meaningfully implemented or tested today because **no backend in the workspace declares `PlexusRequest`**:

- **REQ-6** — plexus-macros emits `x-plexus-source` annotations on per-method param schemas. The annotations have no producer at runtime if no activation uses `request = MyRequest`.
- **REQ-7** — hub-codegen emits JSDoc `@requiresAuth` / `@reads-cookie` / `@reads-header` tags. Output is invisible if the IR's `irPluginRequests` is empty (which it is, today).
- **SAFE-6** — synapse-cc warns when backend advertises cookie auth but client uses URL tokens. The warning never fires today because no backend's `psRequest` declares `auth_token` from cookie.

These three tickets share a single blocker: a live activation in substrate, lforge, or another reachable backend must adopt `request = MyRequest` (REQ-1/REQ-4) so the schema actually carries `psRequest`.

## What was already landed in the autonomous Apr 22 run

- `psRequest :: Maybe Value` on Haskell `PluginSchema` (REQ-S10 spike)
- `irPluginRequests` field on synapse IR (REQ-5 IR layer)
- Help renderer in `Synapse.Algebra.Render` for the activation-level request schema (REQ-5 §3)
- Cookie-capable transport.ts in hub-codegen (SAFE-7)

So the entire pipeline is ready to *receive* a `psRequest` schema; the gap is upstream — no Rust activation in this workspace produces one yet.

## Required behavior (when this ticket activates)

1. Land REQ-6 per its existing acceptance criteria
2. Land REQ-7 per its existing acceptance criteria (depends on REQ-6 for full per-method annotations; the activation-level subset can ship immediately)
3. Land SAFE-6 per its existing acceptance criteria
4. Verify against a backend that declares `PlexusRequest` (substrate's `clients` activation per the FormVeritas project, or a new test fixture)

## What must NOT change

- The IR + renderer + transport.ts already landed — those are `Complete` and load-bearing
- REQ-5's CLI flags (covered by SAFE-S04 separately)

## Acceptance criteria

This is an umbrella ticket; concrete acceptance lives in REQ-6, REQ-7, and SAFE-6 individually.

## Coordination

- Blocked by: a live backend declaring `PlexusRequest` (out of scope for synapse-cc — request via plexus-macros / activation owners)
- Once a consumer exists, the three tickets can fan out in parallel:
  - REQ-6 in plexus-macros
  - REQ-7 in hub-codegen
  - SAFE-6 in synapse-cc

## Completion

Marked Complete when REQ-6, REQ-7, and SAFE-6 are individually Complete.
