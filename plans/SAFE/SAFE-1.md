---
id: SAFE-1
title: "SAFE — synapse-cc parity with current Plexus stack"
status: Epic
type: epic
blocked_by: []
unlocks: []
---

## Goal

synapse-cc 0.4: any developer can point synapse-cc at any current Plexus backend and get a working, typed, auth-aware client without manual flag tweaking. Eliminate silent breakage when the underlying stack moves.

The destination is observable: `synapse-cc init && synapse-cc build` succeeds against substrate, lforge, and any future cookie-auth backend, without `-P`, `--token`, or per-backend flag fiddling. Generated clients use cookie-based WS auth. Stale IR refuses to build against a backend with a major plexus-core bump.

## Dependency DAG

```
SAFE-2 (JWT plumbing)         ───┐
SAFE-3 (registry discovery)   ───┤
SAFE-4 (version gating)       ───┼──► synapse-cc 0.4 ships
SAFE-5 (semantic errors)      ───┤
SAFE-6 (cookie auth warning) ◄── SAFE-7 (cookies on WS upgrade)
```

SAFE-2/3/4 are all synapse-cc-local and run in parallel. SAFE-5 is a synapse renderer change, also parallel. SAFE-6 is `blocked_by: [REQ-5, SAFE-7]` — the warning is only useful once the IR carries `psRequest` and the codegen produces a cookie-capable client.

## Phase Breakdown

### Phase 1 — synapse-cc-local plumbing
SAFE-2, SAFE-3, SAFE-4. Make synapse-cc work against current synapse without manual flags. Pure orchestrator changes.

### Phase 2 — Defensive errors
SAFE-5. synapse decodes the new semantic JSON-RPC error codes so failed builds surface meaningful messages.

### Phase 3 — Cookie auth migration
SAFE-7 first (codegen change), then SAFE-6 (warning). Generated TS clients use cookies on WS upgrade; synapse-cc warns when the configured client transport mismatches the backend's declared auth mode.

## Tickets

| ID | Summary | Status |
|---|---|---|
| SAFE-2 | synapse-cc threads JWT token through Options | Pending |
| SAFE-3 | synapse-cc discovers backends via the Plexus registry | Pending |
| SAFE-4 | synapse-cc version-gates IR against plexus-core | Pending |
| SAFE-5 | synapse decodes semantic JSON-RPC error codes | Pending |
| SAFE-6 | synapse-cc warns on cookie auth mismatch | Pending |
| SAFE-7 | hub-codegen TS client uses cookies on WS upgrade | Pending |

## Out of scope

- Protocol adapter redesign (the half-baked HTTP-method dispatch — pending separate design)
- Multi-language codegen targets (Python, Go)
- Hosted cache (S3/GCS — listed in synapse-cc CLAUDE.md "Future Work")
- Hardware-signer / Keychain auth integration (env-var resolution via shell composition is sufficient — see `--token "$(security find-generic-password ...)"` pattern)
- Bidir Rust parity in hub-codegen (separate small ticket; not blocking 0.4)
- REST/MCP transport client emission (waits for protocol adapter design; informational JSDoc only is in REQ-7)
- Request-extractor JSDoc surfacing (covered by REQ-7, depends on REQ-5/REQ-6 + SAFE-7)
