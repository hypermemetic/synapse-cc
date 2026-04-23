---
id: SAFE-5
title: "synapse decodes semantic JSON-RPC error codes"
status: Pending
type: implementation
blocked_by: []
unlocks: []
severity: Medium
---

## Problem

synapse decodes all JSON-RPC errors as a generic `TransportError` with the raw server message. The new semantic codes emitted by `plexus_error_to_jsonrpc` (`-32001` auth, `-32602` invalid params, `-32601` method not found, `-32000` execution) carry meaning that gets lost. Users see opaque messages like `Error: Authentication required: no token`, with no hint about how to remediate.

## Context

REQ-5 (Ready, not yet shipped) covers the `-32001` case in synapse's renderer with a token-resolution hint. SAFE-5 extends that approach to the other three codes uniformly.

The error codes come from plexus-core's `plexus_error_to_jsonrpc()`:
- `-32001` — unauthenticated / auth required
- `-32602` — invalid parameters
- `-32601` — method or activation not found
- `-32000` — execution error (server threw)
- Other codes — protocol-level (parse error -32700, etc.) — preserved as today

## Required behavior

| Code | Renderer output |
|---|---|
| `-32001` | "Authentication required: <server-msg>" + the token-resolution hint defined in REQ-5 |
| `-32602` | "Invalid parameters: <server-msg>" + suggestion to run `--help` for the method to see expected params |
| `-32601` | "Method not found: <server-msg>" + at least one fuzzy-match suggestion drawn from synapse's existing `CLI.Similarity` module |
| `-32000` | "Execution error: <server-msg>" — no hint added (server-side problem; user can't fix it) |
| Any other code | Existing generic rendering preserved verbatim |

Suggestions for `-32601` use the IR's known method paths to compute Levenshtein distance against the user-typed path, returning the closest match if distance ≤ 3.

## What must NOT change

- Wire format of error responses is unchanged (this is a renderer-only change in synapse)
- Exit code for failed commands remains non-zero
- `--json` output emits raw error JSON unchanged (no rendering applied to JSON output)
- `--raw` output is unchanged
- Existing `-32001` rendering from REQ-5 is not regressed (this ticket can land before, after, or alongside REQ-5)

## Risks

1. **REQ-5 and SAFE-5 may write to the same renderer function.** If REQ-5 ships first, SAFE-5 extends `renderRpcError`. If SAFE-5 ships first, REQ-5 must merge cleanly. Mitigation: SAFE-5 implementor reads REQ-5 (whether shipped or not) before starting; both tickets agree on the function name and signature in `synapse/src/Synapse/Algebra/Render.hs`.
2. **Fuzzy-match suggestions for `-32601`** require IR availability at error rendering time. If the error fires before IR fetch (e.g., `_info` request itself fails with `-32601`), fall back to a generic message with no suggestion.

## Acceptance criteria

1. Calling a non-existent method via `synapse <backend> nope.method` produces stderr containing the substring `Method not found` and at least one method-name suggestion
2. Calling an existing method with malformed params produces stderr containing the substring `Invalid parameters` and a hint pointing at `--help`
3. Calling a method that throws server-side produces stderr containing the substring `Execution error`
4. The auth case (`-32001`) continues to render with REQ-5's token-resolution hint — no regression
5. A protocol error (e.g. `-32700` parse error) renders with the existing generic format, not one of the four semantic templates
6. With `--json`, all four semantic codes emit raw error JSON unchanged — no human-readable rendering applied

## Completion

Implementor adds the renderer cases, exercises each error code via a live backend or test fixture, and shares one stderr capture per code in the commit message. Flips status to Complete.
