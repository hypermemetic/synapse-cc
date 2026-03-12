# synapse-cc: Execution Flow

## Overview

synapse-cc is a Haskell orchestrator that turns a live Plexus backend into
a type-safe client library. It owns three concerns that hub-codegen (the
stateless Rust code generator) does not:

- **Cache** — skip rebuilds when nothing changed
- **Merge** — preserve user edits via SHA-256 three-way merge
- **Orchestration** — IR fetch, codegen, dep install, build, test

---

## Top-Level Command Dispatch

```
synapse-cc <cmd>
      │
      ├─ init         →  write synapse.config.json skeleton, exit
      │
      ├─ build <T> <B>→  single-target build (explicit CLI flags)
      │
      ├─ build        →  read synapse.config.json, build all targets
      │
      └─ watch <B>    →  initial build, then poll loop (never returns)
```

Each branch calls `discoverTools` first, then hands off to the pipeline.

---

## Full Build Pipeline

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                        runPipeline                              │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 0 · Cache Validation                               │   │
 │  │                                                          │   │
 │  │  read IR manifest ──── tool versions match?             │   │
 │  │  read code manifest ─┐      │ no → CacheMiss            │   │
 │  │                       │      │ yes                       │   │
 │  │                       └─ per-plugin hash check          │   │
 │  │                              │                           │   │
 │  │              ┌───────────────┼───────────────┐           │   │
 │  │          FullHit         PartialHit        Miss          │   │
 │  │              │               │               │           │   │
 │  │           return          full rebuild   full rebuild    │   │
 │  │           cached path     (index rebuild              │   │
 │  │                            needed for                 │   │
 │  │                            removed plugins)           │   │
 │  └──────────────────────────────────────────────────────────┘   │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 1 · IR Generation                (77 ms wall)      │   │
 │  │                                                          │   │
 │  │  initEnv host port backend                               │   │
 │  │  runSynapseM env (buildIR [] [])  ← in-process library   │   │
 │  │                 │                   (no subprocess)       │   │
 │  │                 └─ parallel WebSocket fetches per plugin │   │
 │  │                 └─ assemble IRData (Haskell type)        │   │
 │  │                 └─ Aeson.encode → write to cache path    │   │
 │  │                                                          │   │
 │  │  cache: ~/.cache/plexus-codegen/synapse/ir/{bk}/ir.json  │   │
 │  └──────────────────────────────────────────────────────────┘   │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 2 · Code Generation              (31 ms wall)      │   │
 │  │                                                          │   │
 │  │  hub-codegen                                             │   │
 │  │    --target typescript                                   │   │
 │  │    --output-format json          ← stdout, no file I/O   │   │
 │  │    --transport ws|browser                                │   │
 │  │    [--plugins ns1,ns2]           ← partial rebuild only  │   │
 │  │    ir.json                                               │   │
 │  │          │                                               │   │
 │  │          └─ parse CodegenOutput from stdout JSON         │   │
 │  │               · files          Map RelPath → Content     │   │
 │  │               · fileHashes     Map RelPath → Hash16      │   │
 │  │               · dependencies   Map Name → Version        │   │
 │  │               · devDependencies                          │   │
 │  └──────────────────────────────────────────────────────────┘   │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 3 · Mode Detection                                 │   │
 │  │                                                          │   │
 │  │  check output dir package.json for "_generatedBy" field  │   │
 │  │                                                          │   │
 │  │  STANDALONE                    INTEGRATION               │   │
 │  │  synapse-cc created it         host project owns it      │   │
 │  │  owns tsconfig + test/         no tsconfig / test/       │   │
 │  │  owns dev deps                 strip dev deps            │   │
 │  │  runs build + test             skips build + test        │   │
 │  └──────────────────────────────────────────────────────────┘   │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 4 · Three-Way Merge              (< 5 ms)          │   │
 │  │                                                          │   │
 │  │  For each generated file:                                │   │
 │  │                                                          │   │
 │  │    cached hash    disk hash    new hash    action        │   │
 │  │    ──────────     ─────────    ────────    ──────        │   │
 │  │    (none)         (none)       H           write         │   │
 │  │    H              H            H           skip          │   │
 │  │    H              H            H'          write         │   │
 │  │    H              H' ≠ H       any         skip  ← user  │   │
 │  │                                                 modified │   │
 │  │                                                          │   │
 │  │  hash = SHA-256(utf8)[..16 hex chars]                    │   │
 │  │         same algorithm as hub-codegen                    │   │
 │  │                                                          │   │
 │  │  then: cleanRemovedFiles (stale files safe to delete)    │   │
 │  └──────────────────────────────────────────────────────────┘   │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 5 · Scaffold (Standalone only)                     │   │
 │  │                                                          │   │
 │  │  write tsconfig.json (always, transport-aware)           │   │
 │  │  write package.json  (once, if missing)                  │   │
 │  └──────────────────────────────────────────────────────────┘   │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 6 · Dependencies                                   │   │
 │  │                                                          │   │
 │  │  read existing package.json deps                         │   │
 │  │  filter: keep only packages not already present          │   │
 │  │  if new packages:  pm add <pkgs>                         │   │
 │  │                    pm add -D <pkgs>                       │   │
 │  │                    pm install                            │   │
 │  │  if all present:   skip (no subprocess)                  │   │
 │  │  if node_modules missing but no new pkgs: pm install     │   │
 │  │                                                          │   │
 │  │  package manager detection (lockfile → binary fallback): │   │
 │  │    bun.lock → bun                                        │   │
 │  │    pnpm-lock.yaml → pnpm                                 │   │
 │  │    yarn.lock → yarn                                      │   │
 │  │    package-lock.json → npm                               │   │
 │  └──────────────────────────────────────────────────────────┘   │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 7 · Build & Test (Standalone, optional)            │   │
 │  │                                                          │   │
 │  │  --no-build:   skip        --no-tests:  skip             │   │
 │  │  integration:  skip        integration: skip             │   │
 │  │                                                          │   │
 │  │  TypeScript build:  pm exec tsc --noEmit                 │   │
 │  │  TypeScript test:   pm test                              │   │
 │  └──────────────────────────────────────────────────────────┘   │
 │                                                                 │
 │  ┌──────────────────────────────────────────────────────────┐   │
 │  │  Step 8 · Write Cache Manifests                          │   │
 │  │                                                          │   │
 │  │  IR manifest:   per-plugin schema hashes + tool versions │   │
 │  │  Code manifest: per-plugin file hashes + tool versions   │   │
 │  │                                                          │   │
 │  │  ~/.cache/plexus-codegen/                                │   │
 │  │  ├── synapse/ir/{backend}/manifest.json                  │   │
 │  │  └── synapse-cc/code/{target}/{backend}/manifest.json    │   │
 │  └──────────────────────────────────────────────────────────┘   │
 └─────────────────────────────────────────────────────────────────┘
```

---

## Cache Validation Detail

```
validateCache
      │
      ├─ --force?  ──yes──→  CacheMiss (skip everything)
      │
      ├─ read IR manifest
      │     missing? ──→ CacheMiss
      │     tool version changed? (synapse-cc, synapse) ──→ CacheMiss
      │
      ├─ read code manifest
      │     missing? ──→ CacheMiss
      │     tool version changed? (+ hub-codegen) ──→ CacheMiss
      │
      └─ validatePluginCaches
             │
             ├─ monolithic "default" entry in code cache?
             │     yes ──→ FullCacheHit
             │
             └─ per-plugin:
                   for each plugin:
                     codeCache[plugin].irHash == irCache[plugin].schemaHash?
                     yes → valid
                     no  → invalid
                   │
                   ├─ all valid  ──→ FullCacheHit
                   └─ some invalid ──→ PartialCacheHit [valid] [invalid]
                         (watch partial rebuild uses this;
                          build always does full rebuild)
```

---

## Watch Mode Loop

```
runWatch
    │
    ├─ load synapse.config.json (fallback: CLI defaults)
    ├─ filterTargets: keep targets with "plugins" in generate list
    │
    ├─ INITIAL BUILD: runPipeline for each active target
    │   (establishes baseline + populates cache)
    │
    └─ POLL LOOP (every pollInterval ms, default 1000):
          │
          ├─ hot-reload? reload synapse.config.json (keep old on error)
          │
          ├─ fetchBackendHash:
          │     RPC call: {backend}.hash
          │     parse StreamData with content_type "*.hash"
          │     extract {"event":"hash","value":"..."} → Text
          │
          ├─ hash unchanged? ──→ no-op (fast path, no I/O)
          │
          └─ hash changed:
                │
                ├─ buildIR (in-process, parallel plugin fetches)
                ├─ write ir.json to cache
                ├─ extractPluginHashesFromBytes (from IR JSON)
                ├─ diffPluginHashes vs cached IR manifest
                │
                ├─ plugins removed?
                │     yes ──→ full rebuild per target (runPipeline)
                │              (partial rebuild can't fix stale index.ts)
                │
                └─ plugins changed:
                      filter by CLI prefix args (--plugins echo health)
                      for each changed namespace × each active target:
                        rebuildPlugin:
                          generateCode --plugins <ns> (hub-codegen)
                          applyMerge (three-way, no cache update)
                      report: "echo (client) rebuilt in 15ms"
```

---

## Data Flow: What Crosses Process Boundaries

```
 synapse-cc (Haskell process)
 ┌─────────────────────────────────────────────────────┐
 │                                                     │
 │  plexus-synapse (library, in-process)               │
 │  ┌─────────────────────┐                            │
 │  │  initEnv            │  WebSocket  ┌────────────┐ │
 │  │  runSynapseM        │◄───────────►│  Plexus    │ │
 │  │  buildIR            │  JSON-RPC   │  backend   │ │
 │  └─────────────────────┘             └────────────┘ │
 │            │                                        │
 │            │ IRData (Haskell type)                  │
 │            ▼                                        │
 │      Aeson.encode ──→ ir.json (disk)                │
 │                            │                        │
 │                    subprocess stdin                 │
 │                            ▼                        │
 │                     ┌────────────┐                  │
 │                     │ hub-codegen│  (Rust process)  │
 │                     │  reads     │                  │
 │                     │  ir.json   │                  │
 │                     └────────────┘                  │
 │                            │ stdout JSON            │
 │                            ▼                        │
 │              parse CodegenOutput                    │
 │              · files → three-way merge → disk       │
 │              · deps  → pm add / pm install          │
 └─────────────────────────────────────────────────────┘
```

The IR crosses the process boundary **once**: encoded to disk, read by hub-codegen.
All merge and cache decisions happen in the Haskell process only.

---

## Profiler Summary (force rebuild, 39 plugins)

```
  Wall time breakdown:
    IR generation (network + JSON parse)   77 ms   62%
    Code generation (hub-codegen process)  31 ms   25%
    Merge + cache + file writes            <5 ms    4%
    Haskell startup + tool discovery       11 ms    9%
                                         ────────
    Total                                 124 ms

  CPU time breakdown (GHC profiler, 100 ms total CPU):
    Aeson JSON parsing (IR decode)         ~47%
    Aeson JSON encoding (IR re-encode)     ~10%
    Network I/O (WebSocket, DNS)           ~13%
    buildIR (IR assembly)                   ~6%
    applyMerge (file merge)                 ~1%
    runProcess (hub-codegen launch)         ~5%
    GHC overhead / MAIN                    ~18%

  GC: 38 ms (25% of elapsed) — from ~115 MB IR allocation in buildIR
  Memory peak: 79 MiB

  Cache hit: 32 ms (just the startup + manifest reads)
```

**The bottleneck is unavoidable network latency** (IR fetch from backend) plus
JSON parsing of the IR payload. The Haskell orchestration itself takes <5 ms.

**One known inefficiency:** the IR is fetched as a Haskell type via `buildIR`,
then re-encoded to JSON for the cache (`Aeson.encode` → 10% of CPU). If the
synapse library exposed raw bytes, this round-trip could be eliminated.

---

## Key Invariants

| Invariant | Where enforced |
|-----------|---------------|
| Hash algorithm identical in Haskell + Rust | `SHA-256(utf8)[..16 hex]` — `Merge.hs:computeFileHash` matches `hub-codegen/src/hash.rs` |
| User modifications never overwritten | Three-way merge: disk hash ≠ cached hash → skip |
| Stale files never blindly deleted | `cleanRemovedFiles`: delete only if disk hash == cached hash |
| Partial rebuild never removes files | Only full rebuild (plugins removed) triggers cleanup |
| cache.json never written on error | `writeCache` called only after pipeline succeeds |
| `package.json` never generated | Written once as starter only; all further changes via `pm add` |
