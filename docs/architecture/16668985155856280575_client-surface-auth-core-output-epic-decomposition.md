# Client Surface, Auth, Core Extraction, and Output — Epic Decomposition

**Date:** 2026-05-02
**Audience:** Future sessions planning work on the Plexus stack downstream of plexus-core/plexus-transport/plexus-macros — specifically synapse-cc, hub-codegen, plexus-gamma, and any work on Plexus-native auth or output ergonomics.
**Purpose:** Capture the design conversation that produced four parallel epics (CLIENTS, AUTHZ, CORE, OUTPUT) and the rationale behind what was scoped in vs. dropped. This is a snapshot of the architectural reasoning so future sessions can pick up without re-deriving the framings from scratch.

---

## TL;DR

A May 2026 audit of the Plexus stack found:

- The synapse CLI binary is roughly **scope-complete** for what a CLI should do
- The hub-codegen Rust target is at **~60% feature parity** with TypeScript
- plexus-gamma is **architecturally close** to "API browser" but missing chrome (auth UI, persistence, bidir UI, sequenced-call handling)
- plexus-substrate **doesn't yet exercise** most of the new plexus-core/transport features (cookie auth, `PlexusRequest` extraction, `SessionValidator`, Origin enforcement) — so the runtime contracts aren't load-bearing in production yet
- Authentication beyond bearer-token is the **largest missing pillar** for shipping Plexus microservices to the public internet
- Default-deny authorization scoping (browser same-origin-policy posture) is a directional commitment that should be made deliberately

The conversation produced four epics, structured to ship value tactically while building toward the long-term architectural goals:

| Epic | Scope | Status |
|---|---|---|
| **CLIENTS** | hub-codegen Rust parity + gamma chrome (persistence, bidir UI) + Origin model spike | 7 tickets in `plans/CLIENTS/` |
| **AUTHZ** | Plexus-native auth + default-deny scoping + privacy primitives | 1 unified spike in `plans/AUTHZ/` |
| **CORE** | Extract Rust IR-builder crate; share types across hub-codegen + gamma (WASM) + future synapse | 1 epic + 2 spikes in `plans/CORE/` |
| **OUTPUT** | Agent-friendly synapse CLI flags (--select, --filter, --table, etc.) | 3 tickets in `synapse/plans/OUTPUT/` |

This document explains why those four epics, why those scopes, and what we explicitly chose not to do.

---

## Context (May 2026)

The plexus stack at this point comprises:

- **plexus-core** — Rust crate; `DynamicHub`, `AuthContext`, `PlexusRequest`, `Handle`, error types
- **plexus-transport** — Rust crate; WebSocket, MCP HTTP, REST gateway, cookie-only WS auth, `SessionValidator`, `ValidOrigin`/`SecureTransport`/`ClientIp` extractors
- **plexus-macros** — Rust proc-macros; `#[activation]`, `#[method]`, `#[derive(PlexusRequest)]`, `#[derive(HandleEnum)]`
- **plexus-substrate** — Rust reference backend; ~17 activations; bearer-token auth only; no cookie auth, no Origin enforcement, no rate limiting, no multi-tenancy
- **synapse** — Haskell CLI; fetches schemas via `_info`, navigates with cycle detection, emits IR, renders via Mustache or NDJSON
- **synapse-cc** — Haskell orchestrator; consumes synapse as a library; coordinates synapse + hub-codegen for end-to-end client codegen
- **hub-codegen** — Rust codegen tool; consumes synapse-emitted IR; produces TypeScript and Rust clients
- **plexus-gamma** — Vue 3 + Bun runtime UI; live-schema invoker; uses synapse-cc-generated `--transport browser` for its own client

Recent additions (since 2026-01-15) that drove the audit:

- `PlexusRequest` trait + `RawRequestContext` for typed HTTP context extraction
- `ChildRouter::router_call` 5th param (`raw_ctx: Option<&RawRequestContext>`) — breaking change
- Semantic JSON-RPC error codes (`-32001`/`-32602`/`-32601`/`-32000`) via `plexus_error_to_jsonrpc()`
- Cookie-only auth on WebSocket (query-param token path removed)
- REST HTTP gateway transport
- `ValidOrigin`/`SecureTransport`/`ClientIp` extractors
- `SessionValidator` trait
- `SAFE` epic in synapse-cc, partial completion (SAFE-5 Complete: semantic error decoding in synapse renderer)

The audit asked: **what's drifted between layers, what's missing in the chrome, what does it take to ship a Plexus microservice to the public internet with peace of mind?**

---

## What we found

### Parity gaps (the original question)

For each plexus-core / plexus-transport / plexus-macros feature added since 2026-01-15, traced whether synapse's IR captures it and whether hub-codegen consumes it:

| Macro / runtime feature | plexus-core exposes | synapse IR captures | hub-codegen emits |
|---|---|---|---|
| `#[activation(request = MyRequest)]` typed extractors | ✅ `PluginSchema.request` | ❌ dropped | ❌ no extractor client |
| `#[derive(PlexusRequest)]` w/ `#[from_cookie/header/query/peer/auth_context]` + `x-plexus-source` | ✅ | ❌ | ❌ |
| `#[from_auth(expr)]` on params | ✅ stripped from RPC schema | ❌ not annotated | ❌ |
| `#[method(http_method = "...")]` | ✅ `HttpMethod` enum | ❌ | ❌ POST-only |
| `#[activation(children = [...])]` | ✅ ChildRouter metadata | ⚠️ partial (cone nav) | ⚠️ TS namespace only |
| `#[derive(HandleEnum)]` | ✅ | ❌ | ❌ |
| ChildRouter `raw_ctx` 5th param (breaking) | ✅ | ❌ no version stamping | n/a |
| Semantic JSON-RPC error codes | ✅ | ✅ (SAFE-5 Complete) | ⚠️ TS only — Rust target has flat `PlexusError` |
| REST HTTP gateway | ✅ | ❌ no client emission | ❌ |
| Cookie-only WS auth | ✅ | n/a | ⚠️ generated TS clients still emit URL token path (silent breakage risk) |
| MCP flat-schema routing | ✅ | ❌ | ❌ |
| `SessionValidator` integration | ✅ | n/a | n/a |

In addition, three IR fields synapse already emits are **silently dropped at hub-codegen's deserializer**:

- `mdBidirResponseType` — bidir response TypeRef (commit `f8506678`)
- `mdBidirResponseSchema` — full JSON Schema for bidir responses
- `irPluginHashes` — V2 plugin cache info

Verified at `hub-codegen/src/ir.rs:308` (MethodDef) and `hub-codegen/src/ir.rs:33` (IR root). serde silently ignores unknown JSON keys.

### Substrate's actual state (the load-bearing question)

A targeted audit of plexus-substrate (May 2026) — see `plexus-substrate/docs/architecture/16668990377026586623_substrate-wire-protocol-and-security-reference.md` — found:

- **Auth today**: Optional bearer token via `--api-key` / `PLEXUS_API_KEY`. **No cookie auth, no JWT, no login activation, no Origin allowlist on WS upgrade, no `SessionValidator` wired, no rate limiting, no connection caps, no multi-tenancy enforcement.**
- `_info` is **open by default** — full schema readable without auth.
- No `#[derive(PlexusRequest)]` patterns in any activation.
- No activation reads `raw_ctx` (propagated by macro through `ChildRouter::router_call`, ignored downstream).
- Bidir reference activation: `interactive` (`src/activations/interactive/activation.rs`) with `wizard` / `delete` / `confirm` methods using `StandardBidirChannel`.
- Streaming protocol has **no version tag** — adding `PlexusStreamItem` variants is silently breaking.
- Synapse `--json` framing confirmed as **NDJSON** (`synapse/app/Main.hs:1016` uses `LBS.putStrLn`).

**The implication:** plexus-core and plexus-transport ship features that the canonical reference backend doesn't exercise. The drift between IR-emitter and IR-consumer is real but lives in feature surfaces with **zero current production users**. This changes priority: closing drift in features without users is defensible (don't let drift accumulate) but should not outrank fixing things real users hit today.

### Rust target status

hub-codegen Rust target is at **~60% TypeScript parity** ("fill in the gaps," not "rewrite"). Foundation works: types, async client, transport, streaming, multi-plugin namespacing, Cargo.toml emission. Notable gaps:

- Bidir handlers entirely missing (`md_bidir_type` parsed, never emitted)
- No typed RPC error class hierarchy (TS has `PlexusRpcError`/`AuthenticationError`/`InvalidParamsError`/`MethodNotFoundError`/`ExecutionError`; Rust has flat `PlexusError`)
- IR-9 typed handles are skeleton-only (`DynamicChild` impls return `serde_json::Value` instead of typed clients; `hub-codegen/src/generator/rust/client.rs:474`)
- IR-7 deprecation untested in Rust integration tests
- rustdoc parity vs JSDoc untested

### Gamma's architecture

plexus-gamma is a Vue 3 + Bun bridge app at `/Users/shmendez/dev/controlflow/hypermemetic/plexus-gamma/`. The Bun server is **not** on the auth/RPC path — the browser opens its own WS directly to each backend. Bun is for app-builder, headless screenshots, Claude chat integration.

Connection lifecycle: user adds backend via `App.vue:42-49` → `useBackends.addConnection()` → `getSharedClient()` → `rpc.connect()` opens WS at `transport.ts:90` → `_info` fetched, schema tree parsed, method index flattened. **Connections live in a module-level reactive `ref`** (`useBackends.ts:77`) — memory-only, no localStorage, defaults to `[{ name: 'substrate', url: 'ws://127.0.0.1:4444' }]` on every reload.

Schema model (`plexus-schema.ts`) parses `_info` into a `PluginSchema` tree. `MethodSchema` already includes a `request_type` field — fetched, parsed, **then ignored** (no UI consumes it). Forms render via `SchemaField.vue`'s recursive JSON-Schema renderer.

Bidir transport plumbing exists (`transport.ts:141-168` — `onBidirectionalRequest`, `sendBidirectionalResponse`) but **no UI wires to it**. Bidir methods stall when invoked from gamma.

Auth: **zero**. No login form, token field, or credential input. WebSocket connections opened to any URL without headers.

### What's actually needed for "ship to the public internet"

A pre-flight checklist materialized:

- Origin allowlist enforced on WS upgrade (capability exists in plexus-transport, not wired in substrate)
- `_info` auth-gated or scoped by caller
- Rate limits on connections + subscriptions
- `raw_ctx` scoping rules per activation
- `from_header` only behind a trusted gateway
- Sane cookie defaults
- TLS verified end-to-end
- Secrets never in error messages
- Multi-tenant isolation enforced (today: per-activation policy, not framework-enforced)

Most of these are **missing primitives** in the stack today, not just configuration. Threat-modeling them surfaced authorization (RBAC/scoping) and privacy primitives (schema projection, sensitive-field tagging, audit log) as the work that AUTHZ epic must own.

---

## Framings that shaped the decisions

These conceptual lenses repeatedly clarified or corrected directions during the conversation. They're worth carrying forward.

### 1. Synapse the CLI is roughly scope-complete

Initially I thought synapse needed feature additions (capture more IR fields, decode more error codes, etc.). After the audit:

- Synapse already has `--json` (NDJSON), Mustache rendering, `_self` credential management, schema fetch with cycle detection, IR emission, parameter validation, bidir CLI modes
- The agent-friction complaints I originally had mostly dissolved on inspection (NDJSON works, `_self` exists, credentials store works)
- Where additions ARE valuable, they're CLI ergonomics (the OUTPUT epic) not capability gaps

**Implication:** stop pushing features into synapse. Push them into the consumers (chrome) and into the runtime contract (substrate exercising what the macros expose).

### 2. The browser metaphor — half right, in a specific way

I initially framed gamma as approaching "an API browser" and tried to map every browser concept to Plexus. Some maps cleanly (Origin, address bar, cookies, cache). Some don't (browser permissions = camera/mic/files, which Plexus has no analog for because everything is server-side).

The corrected framing:

- **Methods = forms = state transitions.** No new primitive needed.
- **Sequenced calls = navigation.** Multiple state transitions compose, with state persisted between them via cookies / headers / `raw_ctx` forwarding. Browsers don't hold one connection across an auth flow — they sequence requests with state in cookies. Plexus does the same.
- **Bidir = mid-call data dependency.** Reserved for cases where you genuinely can't tear down and resume — long-running operation paused for input, transactional flow needing MFA mid-flight. Optimization, not foundation.
- **Authentication = sequenced calls** (probably). Server says "go login first," client does, comes back. Like HTTP 401. Not bidir.

**Implication:** the chrome's central job is **sequenced state-machine driving**, not bidir form rendering. Bidir UI is still useful (CLIENTS-6) but it's the smaller class.

### 3. Authentication + authorization + privacy are entangled

The user steered the conversation to a critical point: shipping microservices to the public internet requires more than "AuthContext threading" (which the existing AUTH-1..8 epic delivers). It requires:

- **Identity** — login flows, multi-mechanism auth per backend, SSO/OIDC
- **Authorization** — default-deny scoping, roles, hub-level policies, framework-enforced
- **Privacy** — schema projection, sensitive-field tagging, audit logging, no enumeration via errors
- **Discoverability** — capability advertisement so clients can drive the right flow
- **Credential isolation** — per-Origin scoping in clients

Trying to ticket these separately leads to the wrong shape, because they interlock. AUTHZ-S01 is one unified spike covering all of them — output is a coherent design that gets sliced into implementation epics afterward.

### 4. Default-deny scoping is the directional commitment

Browsers got safer because same-origin policy is **default-on**; you explicitly opt out (CORS) per resource. The same posture for Plexus: every method has scope `<activation>.<method>` implicitly; without an `AuthContext` carrying that scope (or a role containing it), the call is rejected. Public methods are explicitly marked.

This breaks every existing substrate activation on day one. The migration is real work. But the alternative — default-allow with opt-in scoping — means the burden of proof is "I want this open" instead of "I forgot to lock this." Browser experience says default-deny pays off massively.

This is a directional commitment that should be made deliberately. AUTHZ-S01's task 12 ("migration story") forces the explicit decision.

### 5. The contract isn't load-bearing yet

The single most important reframing: plexus-core / plexus-transport / plexus-macros have been shipping rich features (request extraction, semantic errors, cookie auth, REST gateway, MCP routing, SessionValidator, Origin extractors). **Substrate uses none of it.** No `from_cookie`/`from_header`/`from_auth_context` patterns, no SessionValidator wired, no cookie auth, no Origin enforcement.

So the "synapse drops mdRequestSchema" drift is real, but it's drift in a feature with zero current production users. Fixing it is defensible (don't let drift accumulate) but it shouldn't outrank fixing things real users hit today.

**The biggest unlock: build one reference activation that exercises the new auth surface end-to-end.** Without this, codegen tickets for cookie auth + request extractors generate client code for a contract no one is testing server-side.

This insight is folded into AUTHZ-S01's follow-up implementation tickets (the spike output identifies the substrate reference activation as one of the next concrete deliverables).

### 6. Drift prevention by construction

CLIENTS-2 fixes the current drift (three missing fields in hub-codegen's IR mirror). CORE-5 (downstream of the CORE epic) eliminates the drift class **structurally**: hub-codegen imports the canonical IR types from a shared `plexus-ir-builder` Rust crate, so adding a synapse-side field automatically appears in hub-codegen.

CORE additionally lets gamma replace its third independent representation (`plexus-schema.ts`) with the same canonical types via WASM. Three places that all need to agree → one place.

This is months-not-weeks work, deliberately separated from CLIENTS (which ships value tactically via drift fixes today).

### 7. Bun proxy was the wrong default for cross-origin

I initially proposed a Bun proxy as the primary path for gamma to reach arbitrary auth-protected backends, because "browsers can't set headers on WS." Correction: browsers CAN connect cross-origin to backends that opt in (CORS-aware Origin allowlist + cookies with `SameSite=None; Secure` + subprotocol smuggling for tokens). The Bun proxy is a **fallback** for legacy backends that won't add CORS, not the default.

This is now reflected in CLIENTS-S01's investigation tasks — primary handshake options first, Bun proxy as a documented fallback.

---

## Epic decomposition

Four parallel epics, plus two existing ones.

### CLIENTS (`plans/CLIENTS/`)

**Goal:** Every client surface (TS codegen, Rust codegen, gamma) reaches feature parity with the current Plexus stack.

**Tickets:**

- **CLIENTS-1** epic overview
- **CLIENTS-2** hub-codegen IR exposes bidir response type/schema (deserializer drift fix; unblocks CLIENTS-4)
- **CLIENTS-3** Rust target typed RPC error classes (parity with TS `PlexusRpcError` family)
- **CLIENTS-4** Rust target bidir handlers (blocked_by CLIENTS-2)
- **CLIENTS-5** gamma persists Origin state to localStorage
- **CLIENTS-6** gamma generic bidir UI (renders confirm/prompt/select; falls back to SchemaField for unknown shapes; displays Origin URL prominently for spoofing defense)
- **CLIENTS-S01** spike: Origin model — per-backend identity, auth-state machine, sequenced-call protocol, cross-origin handshake contract

**Why this scope:** all "make existing surfaces correctly expose what's already in the IR/runtime." Tactical, ships value soon. Origin model spike is the long-term primitive that future credential-isolation work depends on.

### AUTHZ (`plans/AUTHZ/`)

**Goal:** Plexus-native authentication + authorization + privacy primitives. The sequel to the existing AUTH epic.

**Tickets:**

- **AUTHZ-S01** unified spike covering: capability advertisement, standard `auth.*` activation contract, default-deny scoping with migration story, scope/role types, schema projection, `#[sensitive]` field tagging, audit log primitive, no-enumeration error policy, OIDC fit, per-Origin isolation rules

**Why one spike, not many:** the design decisions interlock. Picking the wrong shape in any one ossifies and forces rework in the others. Output is a coherent design note that subsequently gets sliced into implementation epics (likely `AUTHZ-CORE`, `AUTHZ-PRIVACY`, `AUTHZ-FLOWS` per spike output's section 12).

**Coordination with CLIENTS-S01:** the Origin model is owned by CLIENTS-S01; AUTHZ-S01 specifies what gets stored against an Origin. Cross-references, not duplication.

### CORE (`plans/CORE/`)

**Goal:** Extract a Rust IR-builder core; share types across hub-codegen + future synapse + gamma (via WASM). Eliminate the drift class by construction.

**Tickets:**

- **CORE-1** epic overview
- **CORE-S01** spike: identify the minimum reusable subset of synapse to port (schema fetch + navigation + IR build, *not* `_self` / mustache / bidir CLI / protocol validator)
- **CORE-S02** spike: WASM bindings shape (wasm-bindgen vs alternatives, bundle size budget, async/streaming story, TypeScript type sharing, Vite integration)
- **CORE-2** (after spikes) implement `plexus-ir-builder` crate
- **CORE-3** WASM build pipeline + npm package
- **CORE-4** gamma adopts WASM core, deletes `plexus-schema.ts`
- **CORE-5** hub-codegen consumes shared IR types; deletes `src/ir.rs` mirror

**Why deferred from immediate execution:** months-not-weeks initiative. Doesn't gate anything tactical. Long-term architectural payoff: the next drift class is prevented by construction.

### OUTPUT (`synapse/plans/OUTPUT/`)

**Goal:** Agent-friendly stream shaping for synapse CLI; replace temp-file workarounds with native flags.

**Tickets:**

- **OUTPUT-1** epic overview
- **OUTPUT-2** stream-shaping flags (`--select`, `--filter`, `--head`, `--tail`, `--count`); establishes the renderer dispatch hook
- **OUTPUT-3** table renderer (`--table`, `--columns`, `--max-width`, `--format`); blocked_by OUTPUT-2

**Why this scope:** the temp-file pattern was directly observed (`synapse … > /tmp/x.txt && grep "..."`). NDJSON output already in place; projection at the synapse client is mechanical. Tables are a separate rendering path because Mustache is logic-less and ill-suited to adaptive column widths.

**Why synapse-only (per-crate plans/):** OUTPUT doesn't escape synapse — pure CLI work.

### Existing epics referenced (not re-ticketed)

- **AUTH** (`plans/AUTH/AUTH-1..8`) — foundational `AuthContext` threading. Older inline format. AUTHZ-S01 is its sequel.
- **SAFE** (`synapse-cc/plans/SAFE/`) — synapse-cc parity work; SAFE-5 (semantic JSON-RPC errors in synapse renderer) Complete. Other tickets Pending.
- **UX** (`synapse-cc/plans/UX/`) — earlier UX overhaul epic.

---

## Explicitly dropped

Items discussed and chosen NOT to ticket, with reasons. This list matters — future sessions should understand what was considered and rejected, not re-derive it.

| Item | Why dropped |
|---|---|
| **plexus-derive integration** | "Not being used. Anything from plexus-derive should not be considered whatsoever." Saved as project memory. |
| **plexus-ir Rust AST crate consumption** | Used only by plexus-derive; out of scope by extension. |
| **`#[method(http_method = "GET\|POST\|...")]` dispatch in IR/codegen** | "That implementation is a little half baked. We should be considering a more complete protocol adapter protocol rather than the current bolted on one." Deferred pending protocol-adapter redesign. |
| **REST gateway client codegen (verb-dispatch)** | Same protocol-adapter blocker. Transport itself remains in scope; how methods bind to verbs is the half-baked part. |
| **`HandleEnum` codegen support** | Only test-fixture usage in workspace today; raw `Handle` struct already round-trips through hub-codegen → TS clients. Re-evaluate when first production caller appears outside substrate. |
| **`irPluginHashes` deserializer addition in hub-codegen** | synapse-cc consumes synapse as a Haskell library and reads V2 cache info directly; hub-codegen has no current use for plugin-level hashes. |
| **IR-9 typed-child wiring (`DynamicChild` returning typed clients)** | Skeleton exists; needs design spike to determine the typed-child shape before tickets. |
| **IR-7 deprecation integration test for Rust target** | Quality-of-life; not blocking parity. |
| **rustdoc parity test against TS JSDoc test** | Quality-of-life. |
| **Method-level "are you sure?" consent prompts** | Conceded as a fake problem — server-side authz via Request extraction handles "can the user do this." |
| **plexus-core version stamping in IR + stale-IR refusal** | Solves a hypothetical problem; the breaking change that motivated it (ChildRouter `raw_ctx`) doesn't affect synapse since synapse isn't a router. Premature. |
| **Bun proxy as primary auth solution for gamma** | Replaced by direct browser approach with backend opt-in (CORS allowlist + cookie/subprotocol/first-frame-auth handshakes). Bun proxy stays as documented fallback in CLIENTS-S01. |
| **`--summary` aggregation flag, `--jq EXPR` passthrough, large-output stderr hint** | Considered for OUTPUT epic; explicitly out-of-scope of initial epic. Worth doing later as standalone additions. |
| **Mustache template helpers for table layouts** | Mustache is logic-less and ill-suited to adaptive widths. Table renderer bypasses Mustache entirely. |
| **Server-side content-type hints for default rendering** | OUTPUT-1 notes this as future additive optimization; not blocking client-side OUTPUT work. |
| **Porting synapse's full CLI surface to Rust** | CORE-1 explicitly scopes only the IR-builder library subset. `_self`, mustache, interactive bidir, protocol validator stay in the Haskell binary. |
| **Replacing the Haskell synapse binary outright** | Possible future once the Rust core matures; not in any current epic. |
| **Reference auth-using activation for substrate (standalone ticket)** | Folded into AUTHZ-S01's follow-up implementation tickets. The spike will identify it as one of the next concrete deliverables. |

---

## Open architectural questions (the spikes will resolve)

These are deliberately not yet decided. The four spike tickets are designed to resolve them.

### CLIENTS-S01 will pin

- Origin type definition (newtype around URL with auth-state machine)
- The cross-origin auth handshake contract (cookie-with-SameSite=None vs subprotocol smuggling vs first-frame-auth)
- Origin allowlist enforcement shape in plexus-transport's WS upgrade
- Per-Origin credential isolation invariants
- Sequenced auth flow: error code + discoverability hint + retry pattern

### AUTHZ-S01 will pin

- Capability advertisement schema and where it's served
- Standard `auth.*` activation contract (or `plexus-auth` crate proposal)
- Default-deny posture decision + substrate migration story
- Scope/role declaration syntax (macro form + runtime registration form + hub-level composition)
- Schema projection algorithm
- `#[sensitive]` redaction rule
- Audit log primitive
- "No enumeration via errors" policy
- OIDC fit (designed-for, not implemented in initial epic)

### CORE-S01 will pin

- Module-by-module classification of synapse's source tree (Core / CLI / Boundary)
- Proposed Rust crate API surface
- Reuse map (which plexus-core / plexus-transport types are imported vs reimplemented)
- Migration sketch for hub-codegen and gamma

### CORE-S02 will pin

- WASM toolchain (wasm-bindgen / wasm-pack / wit-bindgen / Component Model)
- Bundle size budget (measured)
- WebSocket strategy (Rust-side WS via web-sys vs JS-side WS with Rust parsing)
- Async/streaming pattern across native + WASM
- TypeScript type sharing strategy
- Cargo feature flag conventions for native-vs-WASM splits

---

## How to read the tickets

All tickets follow the `ticketing` skill format (`hypermemetic/skills/skills/ticketing/SKILL.md`):

- YAML frontmatter with `id`, `title`, `status: Pending`, `type`, `blocked_by`, `unlocks`, `confidence`, `severity`
- Body sections: Problem, Context, **Evidence** (load-bearing — the BLF-style sufficient statistic), Required behavior (input/output tables), What must NOT change (regression criteria), Risks, Acceptance criteria, Completion
- Strong-typed contracts per the `strong-typing` skill (`hypermemetic/skills/skills/strong-typing/SKILL.md`) — references to `Origin`, `Scope`, `RoleName`, `FieldName` etc., not "a string containing X"

**Ticket promotion:** all tickets are written `Pending`. Only the human flips to `Ready`. Implementation must not begin on `Pending` tickets.

**Cross-crate vs per-crate location:** top-level `plans/` is the default for cross-crate epics (CLIENTS, AUTHZ, CORE). Per-crate `plans/` is used when the epic genuinely doesn't escape one crate (OUTPUT lives in `synapse/plans/`).

**Reading order suggestion:**

1. CLIENTS-1 (epic overview, narrates the Phase 1-4 sequence)
2. CLIENTS-2 (the immediate drift fix; smallest concrete win)
3. AUTHZ-S01 (the biggest design surface; read this before any auth-related implementation work)
4. CORE-1 + CORE-S01 + CORE-S02 (long-term architectural direction)
5. OUTPUT-1 (independent track; can ship anytime)

---

## Pointers

- **Ticketing skill:** `hypermemetic/skills/skills/ticketing/SKILL.md`
- **Strong-typing skill:** `hypermemetic/skills/skills/strong-typing/SKILL.md`
- **Substrate wire-protocol & security reference:** `plexus-substrate/docs/architecture/16668990377026586623_substrate-wire-protocol-and-security-reference.md`
- **Substrate technical-debt audit:** `plexus-substrate/docs/architecture/16670380887168786687_substrate-technical-debt-audit.md`
- **Existing AUTH epic (foundational):** `plans/AUTH/AUTH-1..8.md`
- **Existing SAFE epic (synapse-cc local):** `synapse-cc/plans/SAFE/SAFE-1..7.md` + spikes
- **CLIENTS epic:** `plans/CLIENTS/CLIENTS-1..6 + S01.md`
- **AUTHZ epic spike:** `plans/AUTHZ/AUTHZ-S01.md`
- **CORE epic:** `plans/CORE/CORE-1, S01, S02.md`
- **OUTPUT epic:** `synapse/plans/OUTPUT/OUTPUT-1..3.md`
