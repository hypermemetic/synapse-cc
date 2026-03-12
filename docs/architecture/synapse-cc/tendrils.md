# Draft: synapse-cc Tendrils — Precise Generation Invocation

**Status**: Draft / Proposal
**Date**: 2026-03-08

---

## Executive Summary

Today synapse-cc treats hub-codegen as a black box: one subprocess call, one IR, one global flag
set, all files out. This conflates two distinct concerns — *what to generate* and *how to configure
it* — and makes any per-artifact variation impossible. More fundamentally, it forces a single
"mode" decision (standalone vs. host-integrated) that should not be a global switch at all.

**Tendrils** is a proposed evolution with two interlocking parts:

**1. Precise generation.** synapse-cc invokes hub-codegen as a set of targeted, composable steps.
Each tendril specifies which artifacts to generate, which transport to use, which plugins to
include, and where to write the output. synapse-cc owns the composition.

**2. Host-first deployment model.** The default assumption is that the generated code lives inside
an existing, already-initialized host project (a Tauri app, a Node service, a monorepo package).
synapse-cc drops `.ts` files into `outputDir`, injects runtime deps into the host's package
manager, and runs nothing else unless explicitly asked. A `--standalone` flag opts into a
self-contained generated package with its own `package.json`, tsconfig, and test runner.

Together these changes make the standalone/integration distinction explicit and composable rather
than heuristically detected, make transport configuration per-artifact rather than global, and give
the smoke test a fixed, isolated execution path that does not touch the host's `test` script.

---

## Problem Statement

### Current shape

```
synapse-cc typescript substrate --transport browser
    └─ hub-codegen --target typescript --output-format json --transport browser ir.json
           └─ CodegenOutput { files: { transport.ts, rpc.ts, echo/client.ts, ... } }
```

Problems with this:

- `--transport browser` applies globally. There is no way to say "the client uses browser
  WebSocket but the smoke test needs ws."
- Integration detection is heuristic — synapse-cc tries to infer whether it's inside a host
  project by inspecting the filesystem, which fails when the CWD happens to have a
  `package.json` (e.g. the synapse-cc source repo itself). Caused stale `package.json`
  scripts that persisted through `--force` runs.
- Smoke tests hardcode substrate-specific method calls (`echo.once`, `health.check`). They
  require domain knowledge and a fully-configured backend; they break if plugins change.
- The host's `test` script is invoked directly, which may run lint, e2e tests, or arbitrary
  tooling. There is no isolation guarantee.
- `starterPackageJson` was written heuristically; the whole package ownership model was
  implicit and fragile.

### What tendrils enable

```
synapse-cc typescript substrate --transport browser
    ├─ tendril: transport  → hub-codegen ... --generate transport --transport browser  → outputDir/
    ├─ tendril: rpc        → hub-codegen ... --generate rpc                            → outputDir/
    ├─ tendril: plugins    → hub-codegen ... --generate plugins                        → outputDir/
    └─ tendril: smoke      → hub-codegen ... --generate smoke --transport ws           → .synapse/smoke/
```

Each tendril is an independent, targeted call with its own options and output directory.
synapse-cc owns the composition. The smoke test goes to `.synapse/smoke/` — never inside the
host's source tree, never routed through the host's `test` script.

---

## Deployment Model: Host-First by Default

### The core principle

Assume the host project already exists and is already initialized as a valid package for its
language. synapse-cc's job is to drop code into it and wire up deps — not to own the project.

Skipping initialization (writing `package.json`, `tsconfig.json`) can be forced with
`--standalone`, but this is not the default or recommended path. A standalone generated project
can always be created later; it is much harder to un-pollute a host project that got an
unwanted `package.json` written into it.

### Default (host-integrated) behaviour

```
synapse-cc typescript substrate -o src/lib/plexus --transport browser
```

- Writes `.ts` source files to `outputDir` via three-way merge
- Does **not** write `package.json` or `tsconfig.json` to `outputDir`
- Does **not** write test scaffold to `outputDir`
- Injects runtime deps into the **host's** package manager (CWD)
- Writes smoke test to `.synapse/smoke/` (see Smoke Tests section)
- Runs smoke test via `<pm> exec bun .synapse/smoke.ts`
- Does **not** run the host's `test` script

### Standalone mode (`--standalone`)

```
synapse-cc typescript substrate --standalone
```

- Writes all generated artifacts to `outputDir` including `package.json`, `tsconfig.json`,
  and `test/smoke.test.ts`
- Installs deps in `outputDir` (`bun install`)
- Runs `bun x tsc --noEmit` in `outputDir`
- Runs `bun test outputDir/test/` in `outputDir`
- Self-contained; the generated dir is a complete package

### Why not detect automatically?

Heuristic detection of host vs. standalone based on whether the CWD has a `package.json`
is unreliable — it fails when:
- The user runs synapse-cc from a directory that incidentally has a `package.json` (e.g. a
  repo root, a tools directory, the synapse-cc source itself)
- The output directory has a stale generated `package.json` without the expected marker
- Nested monorepo layouts where multiple `package.json` files exist at different levels

Making the mode explicit removes all of this. The `--standalone` flag is opt-in; absence
means host-integrated.

---

## Proposed hub-codegen Changes

### `--generate <artifact>` selector

A new flag that restricts what hub-codegen produces:

```
--generate all         (current behaviour, default)
--generate transport   transport.ts only
--generate rpc         rpc.ts only
--generate plugins     plugin client files only (combine with --plugins)
--generate smoke       smoke test file only (written to a separate location)
--generate package     package.json only
```

Each selector maps to one internal generation function. The output `CodegenOutput.files` map
contains only the requested subset.

### `--plugins <names>` filter

```
--plugins echo,health,registry
```

Restricts plugin-client generation to named plugins. Useful for incremental runs when only
some plugins changed.

### Hub-codegen stays stateless

These flags add no state. hub-codegen still takes an IR, applies generation options, and
returns a `CodegenOutput` subset. No new disk I/O. Idempotent.

---

## Proposed synapse-cc Changes

### `Tendril` type

```haskell
data Tendril = Tendril
  { tGenerate  :: GenerateSelector      -- which artifact(s)
  , tTransport :: Maybe TransportType   -- override global transport for this tendril
  , tPlugins   :: Maybe [PluginName]    -- plugin filter (Nothing = all)
  , tOutputDir :: Maybe FilePath        -- override output dir (Nothing = use global outputDir)
  }

data GenerateSelector
  = GenAll
  | GenTransport
  | GenRpc
  | GenPlugins
  | GenSmoke     -- smoke test script (goes to .synapse/smoke/ by default)
  | GenPackage
```

### `runTendril`

```haskell
runTendril :: Config -> ToolLocations -> IRPath -> Tendril -> IO (Either SynapseCCError CodegenOutput)
```

Builds the hub-codegen argument list for this tendril and calls `runProcess`. Returns a
partial `CodegenOutput` covering only the requested files.

### `mergeTendrils`

```haskell
mergeTendrils :: [CodegenOutput] -> CodegenOutput
```

Merges multiple partial `CodegenOutput` values into one. Later tendrils override earlier
ones for the same file key.

### Pipeline change

`generateCode` is replaced by `runTendrils`, which executes a `[Tendril]` in order and
merges the results before passing to the existing three-way merge step.

```haskell
runTendrils :: Config -> ToolLocations -> IRPath -> [Tendril] -> IO (Either SynapseCCError CodegenOutput)
runTendrils config tools irPath tendrils = do
  results <- mapM (runTendril config tools irPath) tendrils
  case sequence results of
    Left err   -> pure (Left err)
    Right outs -> pure (Right (mergeTendrils outs))
```

---

## Default Tendril Sets

synapse-cc builds the tendril list from its options. The user never specifies tendrils
directly; they're derived from high-level flags.

### Host-integrated (default)

```haskell
hostTendrils :: TransportType -> FilePath -> [Tendril]
hostTendrils transport smokeDir =
  [ Tendril GenTransport (Just transport) Nothing Nothing
  , Tendril GenRpc       Nothing          Nothing Nothing
  , Tendril GenPlugins   Nothing          Nothing Nothing
  , Tendril GenSmoke     (Just WsTransport) Nothing (Just smokeDir)
  -- GenPackage omitted — host project owns package.json
  ]
```

`smokeDir` defaults to `.synapse/smoke` relative to CWD.

### Standalone (`--standalone`)

```haskell
standaloneTendrils :: TransportType -> [Tendril]
standaloneTendrils transport =
  [ Tendril GenAll (Just transport) Nothing Nothing ]
```

One tendril, all artifacts, same output dir. Equivalent to current behaviour.

### Mixed transport (Tauri — client browser, smoke ws)

```haskell
tauriTendrils :: FilePath -> FilePath -> [Tendril]
tauriTendrils outputDir smokeDir =
  [ Tendril GenTransport (Just BrowserTransport) Nothing (Just outputDir)
  , Tendril GenRpc       Nothing                 Nothing (Just outputDir)
  , Tendril GenPlugins   Nothing                 Nothing (Just outputDir)
  , Tendril GenSmoke     (Just WsTransport)      Nothing (Just smokeDir)
  ]
```

Browser client (no ws import, works in WebView), ws smoke test (bun/Node executor).
Not possible with the current single-invocation model.

---

## Smoke Tests

### Design goals

1. **Isolated execution path.** The smoke test command targets a specific file/directory,
   never the host's `test` script. No risk of triggering lint, e2e, or browser-dependent
   tests.

2. **Host package manager, no special framework.** Run with `<pm> exec bun .synapse/smoke.ts`.
   The host PM provides the executor; bun handles TypeScript execution. No `bun:test`,
   no jest, no vitest — plain assertions, exit code signals pass/fail.

3. **Protocol-level validation only.** The smoke test must not encode domain knowledge of
   specific backend methods. It should validate the Plexus protocol surface: connectivity,
   discovery, and schema coherence across all activations.

4. **Dep install must complete before execution.** The pipeline blocks on dep installation
   (exit code 0) before running the smoke test. If `bun add` or `bun install` fails, the
   smoke test is not executed.

### The schema walk

The generated smoke test uses three Plexus well-known endpoints in sequence:

```
_info                              → { backend: "substrate" }
{backend}.schema                   → { activations: [...], totalMethods: N }
{backend}.activation_schema [ns]   → detailed schema per activation
```

These endpoints exist on every conformant Plexus backend regardless of which plugins are
loaded. No stub responses, no mock data — the smoke test validates the live protocol.

Generated smoke script (`GenSmoke` → `.synapse/smoke.ts`):

```typescript
import { PlexusRpcClient } from "<outputDir>/transport";

const URL  = process.env.PLEXUS_URL ?? "ws://127.0.0.1:4444";
const rpc  = new PlexusRpcClient({ backend: "substrate", url: URL });

function assert(cond: boolean, msg: string): asserts cond {
  if (!cond) { rpc.disconnect(); throw new Error(msg); }
}

await rpc.connect();

// 1. _info — well-known, no namespace, proves connectivity
const info = await rpc.callOnce("_info", null);
assert(typeof info?.backend === "string", "_info must return { backend: string }");
const backend = info.backend;

// 2. schema walk — discover all activations
const schema = await rpc.callOnce(`${backend}.schema`, []);
assert(Array.isArray(schema?.activations), `${backend}.schema must return activations`);
assert(schema.activations.length > 0, `${backend}.schema returned 0 activations`);

// 3. activation_schema per plugin — validates schema coherence
for (const act of schema.activations) {
  const detail = await rpc.callOnce(`${backend}.activation_schema`, [act.namespace]);
  assert(detail != null, `activation_schema for ${act.namespace} must respond`);
}

rpc.disconnect();
console.log(`✓ ${schema.activations.length} activations validated (${backend})`);
```

### Where the smoke test lives

The smoke test goes to `.synapse/smoke/` (sibling to the host project root, gitignored).
This directory is owned entirely by synapse-cc — it is ephemeral and safe to delete.

```
my-tauri-app/
  src/lib/plexus/        ← generated client code (outputDir)
  .synapse/
    smoke/
      smoke.ts           ← generated smoke test (GenSmoke tendril output)
  .gitignore             ← must include .synapse/
  package.json           ← host project (untouched)
```

The `.synapse/smoke/` directory imports from `outputDir` via a relative path computed at
generation time. The smoke command is always:

```
<pm> exec bun .synapse/smoke/smoke.ts
```

This command is:
- Scoped to exactly one file — no test discovery, no glob
- Independent of the host's `"test"` script — `exec` invokes the runner directly
- Deterministic regardless of which package manager the host uses
- Safe to run in CI without a `test` script being configured

### Handling missing deps

When `<pm> exec bun` is used, bun must be available in the host's `node_modules` or PATH.
If bun is not available via the host PM, synapse-cc adds it as a dev dep (`bun add -D bun`)
before running. This is the only dep injection into `devDependencies` in host-integrated mode.

---

## Implementation Plan

### Phase 1: hub-codegen `--generate` flag

1. Add `GenerateSelector` enum to `GenerationOptions`
2. In `typescript/mod.rs`: gate each artifact behind the selector
3. Add `--generate` and `--plugins` CLI flags to `main.rs`
4. Extract smoke test generation into `GenSmoke` selector (separate from `GenTests`)
5. Tests: assert each selector produces only the expected file set

### Phase 2: synapse-cc `Tendril` type and `runTendril`

1. Add `Tendril` and `GenerateSelector` types to `Types.hs`
2. Implement `runTendril` in `Pipeline.hs`
3. Implement `mergeTendrils`
4. Replace `generateCode` call with `runTendrils [Tendril GenAll ...]` — no behaviour change

### Phase 3: Host-first deployment model

1. Add `--standalone` flag to CLI (default: off)
2. Remove `isIntegration` detection logic entirely
3. Default tendril set: `hostTendrils` (no `GenPackage`, smoke to `.synapse/smoke/`)
4. Standalone tendril set: `standaloneTendrils` (all artifacts, one dir)
5. Write `.synapse/smoke/smoke.ts` via `GenSmoke` tendril output
6. Run `<pm> exec bun .synapse/smoke/smoke.ts` (not `<pm> test`)
7. Tests: verify host mode writes no `package.json`/`tsconfig.json` to outputDir

### Phase 4: Smoke test schema walk

1. Replace current `bun:test`-based smoke tests with plain executable schema walk
2. Implement `_info` → `{backend}.schema` → `{backend}.activation_schema` pattern
3. No test framework dependency — plain TypeScript with inline assertions
4. Tests: verify generated smoke script contains `_info` call, no domain-specific method calls

### Phase 5: Mixed transport and advanced tendril sets (future)

1. `tauriTendrils` builder for common Tauri case (browser client + ws smoke)
2. Expose `--tendril` as advanced CLI option or config file key for custom compositions

---

## What Stays the Same

- Three-way merge, cache, and tsconfig steps are unchanged
- hub-codegen remains stateless; each tendril call is independent and idempotent
- The `--transport` flag still works as before
- The existing `CodegenOutput` JSON schema is backward-compatible

---

## Trade-offs

| Concern | Current | Tendrils |
|---------|---------|----------|
| Subprocess calls per run | 1 | N (one per tendril) |
| Configuration expressiveness | Global flags only | Per-artifact overrides |
| Mode detection | Heuristic (fragile) | Explicit `--standalone` flag |
| Smoke test isolation | Runs via host `test` script | Fixed path, `exec` invocation |
| Smoke test correctness | Domain-specific method calls | Protocol-level schema walk |
| Integration mode filtering | Ad-hoc `Map.delete` / `filterWithKey` | Declarative: omit `GenTests`/`GenPackage` |
| Incremental per-plugin regen | Not possible | `GenPlugins + --plugins` filter |
| Complexity | Low | Moderate |

The subprocess overhead for N tendrils is negligible (hub-codegen runs in ~30ms per call).
If IR grows large, tendrils could be batched via stdin streaming — not needed now.
