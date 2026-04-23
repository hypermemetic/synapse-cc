---
id: SAFE-7
title: "hub-codegen TS client uses cookies on WS upgrade"
status: Pending
type: implementation
blocked_by: []
unlocks: [SAFE-6, REQ-7]
severity: High
---

## Problem

plexus-transport's WebSocket transport no longer accepts `?token=` in the upgrade URL — tokens must be in the `Cookie:` header. Existing hub-codegen-generated TS clients that use URL-token construction fail silently on upgrade against any current backend.

This is the most user-visible silent breakage in the stack: regenerate the client, ship it, every request 401s with no diagnostic.

## Context

This work lands in `hub-codegen` (Rust crate that generates TS), not `synapse-cc`. The ticket lives in `synapse-cc/plans/SAFE/` because it is the linchpin of the SAFE epic — SAFE-6 depends on it, REQ-7 depends on it.

The current TS transport.ts emits client code that constructs WS URLs like `ws://host:port/?token=<jwt>` when an `authToken` is configured. The Node path uses the `ws` library, which supports custom headers; the browser path uses native `WebSocket`, which does not — browsers must rely on `document.cookie` being set on the same origin.

## Required behavior

| Environment | How auth flows |
|---|---|
| Generated TS client, Node target, `wsTransport({ authToken: 'jwt' })` | The WS upgrade request carries header `Cookie: access_token=jwt`. No `?token=` in URL. |
| Generated TS client, browser target | The browser's same-origin cookie store supplies `access_token` automatically. JSDoc on the browser transport explains how to set the cookie (typically: server response sets `Set-Cookie: access_token=...; Path=/; SameSite=Strict`). The factory accepts no `authToken` arg in browser mode. |
| Existing app code that calls `wsTransport({ authToken })` | Continues to type-check. Behavior change: the token is now Cookie-bound, not URL-appended. |

The generated transport.ts contains a marker (a stable comment or named export) that SAFE-6's mismatch detection can look for to identify cookie-capable transports.

## What must NOT change

- The transport.ts file remains a single self-contained file (no new modules introduced)
- Public API surface (`Transport` type, `wsTransport` factory, `browserTransport` factory) is unchanged in shape — only auth handling internals change
- Browser vs Node.js auto-detection logic stays as-is
- Methods, namespace modules, and other generated TS files are unaffected
- Generated package.json dependencies are unchanged (the `ws` library already supports custom headers)

## Risks

1. **Browsers cannot set headers on `WebSocket`.** This is a hard browser constraint, not a hub-codegen limitation. The browser transport must rely on document.cookie. Document this loudly in the JSDoc on `browserTransport` so users don't waste time looking for an `authToken` arg that isn't there.
2. **Existing apps may rely on URL tokens working.** Once SAFE-7 ships, regenerating the client will quietly stop sending URL tokens. The mismatch warning (SAFE-6) catches this on subsequent builds; first regeneration after SAFE-7 lands is the silent-break window. Acceptable trade-off — the URL-token path is already broken against current backends.

## Acceptance criteria

1. Inspecting hub-codegen's generated transport.ts: the file contains zero occurrences of the substring `?token=` (URL construction)
2. The generated `wsTransport({ authToken: 'jwt' })` issues a WebSocket upgrade with header `Cookie: access_token=jwt` (verified via a Node test that intercepts the upgrade request)
3. The generated `browserTransport` factory's TypeScript signature accepts no `authToken` argument; its JSDoc contains an explanation of how to set `document.cookie` for auth
4. The generated transport.ts contains a stable identifier (comment or named export) that can be grepped to confirm "this is a SAFE-7-era cookie-capable transport" — the exact identifier is the implementor's choice but must be documented in the ticket completion note for SAFE-6's reference
5. A hub-codegen test asserts the generated transport.ts string contains the SAFE-7 marker AND does not contain `?token=`
6. Regenerating an existing target after SAFE-7 lands does not break TypeScript compilation in caller code that passes `authToken` to `wsTransport`

## Completion

Implementor lands the change in hub-codegen, runs the codegen test suite, and records the SAFE-7 marker identifier in this ticket's completion comment so SAFE-6 implementor can reference it. Flips status to Complete.
