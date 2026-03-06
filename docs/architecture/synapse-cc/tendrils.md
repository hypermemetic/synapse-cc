# Draft: synapse-cc Tendrils — Precise Generation Invocation

**Status**: Draft / Proposal
**Date**: 2026-03-06

---

## Executive Summary

Today synapse-cc treats hub-codegen as a black box: one subprocess call, one IR, one global flag set, all files out. This works but it conflates two distinct concerns — *what to generate* and *how to configure it*. The result is that any per-artifact variation (e.g. "use browser transport for the client but ws for the test scaffolding") requires either forking the whole invocation or adding proliferating flags to a monolithic CLI.

**Tendrils** is a proposed evolution where synapse-cc invokes hub-codegen as a set of targeted, composable generation steps rather than one opaque call. Each tendril specifies the IR slice it cares about, the generation path it wants, and the options for that path. synapse-cc assembles and sequences these calls; hub-codegen remains stateless.

The immediate motivation is transport: orcha-maestro wants browser transport for the runtime client but the generated test scaffold needs `ws` (or no transport at all). Today these cannot coexist in one invocation. Tendrils make this trivial.

---

## Problem Statement

### Current shape

```
synapse-cc typescript substrate --transport browser
    └─ hub-codegen --target typescript --output-format json --transport browser ir.json
           └─ CodegenOutput { files: { transport.ts, rpc.ts, echo/client.ts, ... } }
```

`--transport browser` applies globally. Every generated file sees the same option set. There is no way to say "transport.ts gets browser semantics, but the test smoke file should use ws" or "generate only the echo plugin client, not the rest."

### What tendrils enable

```
synapse-cc typescript substrate --transport browser
    ├─ tendril: transport  → hub-codegen ... --generate transport --transport browser
    ├─ tendril: rpc        → hub-codegen ... --generate rpc
    ├─ tendril: plugins    → hub-codegen ... --generate plugins --plugins echo,health
    └─ tendril: tests      → hub-codegen ... --generate tests --transport ws
```

Each tendril is an independent, targeted call. synapse-cc owns the composition — which tendrils run, in what order, with what options, and how their outputs are merged before the three-way merge step.

---

## Proposed hub-codegen Changes

### `--generate <artifact>` selector

A new flag that restricts what hub-codegen produces:

```
--generate all         (current behaviour, default)
--generate transport   transport.ts only
--generate rpc         rpc.ts only
--generate plugins     plugin client files only (combine with --plugins)
--generate tests       test scaffold only
--generate package     package.json only
```

Each selector maps to one internal generation function. The output `CodegenOutput.files` map contains only the requested subset.

### `--plugins <names>` filter

```
--plugins echo,health,registry
```

Restricts plugin-client generation to named plugins. Useful for incremental runs when only some plugins changed.

### Hub-codegen stays stateless

These flags do not add state. hub-codegen still takes an IR, applies generation options, returns a `CodegenOutput` subset. No new disk I/O. Idempotent.

---

## Proposed synapse-cc Changes

### `Tendril` type

```haskell
data Tendril = Tendril
  { tGenerate  :: GenerateSelector      -- which artifact(s)
  , tTransport :: Maybe TransportType   -- override global transport for this tendril
  , tPlugins   :: Maybe [PluginName]    -- plugin filter (Nothing = all)
  , tOutputDir :: Maybe FilePath        -- override output dir for this tendril
  }

data GenerateSelector
  = GenAll
  | GenTransport
  | GenRpc
  | GenPlugins
  | GenTests
  | GenPackage
```

### `runTendril`

```haskell
runTendril :: Config -> ToolLocations -> IRPath -> Tendril -> IO (Either SynapseCCError CodegenOutput)
```

Builds the hub-codegen argument list for this tendril and calls `runProcess`. Returns a partial `CodegenOutput` covering only the requested files.

### `mergeTendrils`

```haskell
mergeTendrils :: [CodegenOutput] -> CodegenOutput
```

Merges multiple partial `CodegenOutput` values into one. Later tendrils override earlier ones for the same file key — giving synapse-cc precise control over which generation path "wins" per file.

### Pipeline change

`generateCode` is replaced by `runTendrils`, which executes a `[Tendril]` in order and merges the results before passing to the existing three-way merge step. The rest of the pipeline (merge, tsconfig, package.json, toolchain, cache) is unchanged.

```haskell
runTendrils :: Config -> ToolLocations -> IRPath -> [Tendril] -> IO (Either SynapseCCError CodegenOutput)
runTendrils config tools irPath tendrils = do
  results <- mapM (runTendril config tools irPath) tendrils
  case sequence results of
    Left err  -> pure (Left err)
    Right outs -> pure (Right (mergeTendrils outs))
```

---

## Default Tendril Sets

synapse-cc builds the tendril list from its options. The user never specifies tendrils directly; they're derived from high-level flags.

### Standalone (current behaviour, unchanged)

```haskell
defaultTendrils :: TransportType -> [Tendril]
defaultTendrils transport =
  [ Tendril GenAll (Just transport) Nothing Nothing ]
```

One tendril, same as today.

### Integration (Tauri)

```haskell
integrationTendrils :: TransportType -> [Tendril]
integrationTendrils transport =
  [ Tendril GenTransport (Just transport) Nothing Nothing
  , Tendril GenRpc       Nothing          Nothing Nothing
  , Tendril GenPlugins   Nothing          Nothing Nothing
  -- GenTests omitted — integration mode never writes test scaffold
  -- GenPackage omitted — synapse-cc writes its own, and integration mode
  --   only adds runtime deps to host package.json
  ]
```

### Mixed transport (future)

```haskell
mixedTendrils :: [Tendril]
mixedTendrils =
  [ Tendril GenTransport (Just BrowserTransport) Nothing Nothing
  , Tendril GenRpc       Nothing                 Nothing Nothing
  , Tendril GenPlugins   Nothing                 Nothing Nothing
  , Tendril GenTests     (Just WsTransport)      Nothing (Just "test/") ]
```

Browser client, ws test scaffolding, different output dirs. Not possible today.

---

## Implementation Plan

### Phase 1: hub-codegen `--generate` flag (1–2 days)

1. Add `GenerateSelector` enum to `GenerationOptions`
2. In `typescript/mod.rs`: gate each artifact behind the selector before inserting into `files`
3. Add `--generate` and `--plugins` CLI flags to `main.rs`
4. Tests: assert each selector produces only the expected file set

### Phase 2: synapse-cc `Tendril` type and `runTendril` (1 day)

1. Add `Tendril` and `GenerateSelector` types to `Types.hs`
2. Implement `runTendril` in `Pipeline.hs` (thin wrapper over current `generateCode`)
3. Implement `mergeTendrils` (fold over `CodegenOutput` maps)
4. Replace `generateCode` call with `runTendrils [Tendril GenAll ...]` — behaviour unchanged

### Phase 3: Integration mode tendril set (1 day)

1. When `isIntegration`, use `integrationTendrils` instead of `defaultTendrils`
2. Remove the `scaffolding` filter from `Pipeline.hs` — now handled by not emitting `GenTests`
3. Tests: verify integration mode emits no test/ files, no tsconfig, correct transport

### Phase 4: Mixed transport (future, as needed)

1. Expose `--tendril` as an advanced CLI option or config file key
2. Build `mixedTendrils` builder for the common Tauri case

---

## What Stays the Same

- The three-way merge, cache, and tsconfig steps are unchanged
- hub-codegen remains stateless; each tendril call is independent and idempotent
- The user-facing `--transport` flag still works as before (mapped to `defaultTendrils`)
- The existing `CodegenOutput` JSON schema is backward-compatible (files is still a map; missing keys just mean that tendril didn't produce them)

---

## Trade-offs

| Concern | Current | Tendrils |
|---------|---------|----------|
| Subprocess calls per run | 1 | N (one per tendril) |
| Configuration expressiveness | Global flags only | Per-artifact overrides |
| Complexity | Low | Moderate |
| Integration mode filtering | Ad-hoc Map.delete / Map.filterWithKey | Declarative: just don't emit GenTests |
| Future: per-plugin incremental regen | Not possible | Straightforward (GenPlugins + --plugins filter) |

The subprocess overhead for N tendrils is negligible at current IR sizes (hub-codegen runs in ~30ms). If IR grows large, tendrils could be batched via stdin streaming — but that's not needed now.
