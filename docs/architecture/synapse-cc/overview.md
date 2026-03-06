# synapse-cc Architecture Overview

**Status**: Production
**Date**: 2026-03-06
**Components**: synapse-cc (Haskell), hub-codegen (Rust), orcha-maestro (Vue/Tauri)

---

## System Roles

```
┌─────────────────────────────────────────────────────────────────┐
│ hub-codegen (Rust)                                              │
│ Pure, stateless code generator.                                 │
│ IR JSON → structured output (files map + file hashes + deps)   │
│ No file I/O in JSON mode. No toolchain knowledge.              │
└─────────────────────────┬───────────────────────────────────────┘
                           │ subprocess, --output-format json
┌─────────────────────────▼───────────────────────────────────────┐
│ synapse-cc (Haskell)                                            │
│ Orchestrator. Owns all side effects:                            │
│  - IR generation (calls synapse binary)                         │
│  - Code generation (calls hub-codegen)                          │
│  - Three-way merge and cache                                    │
│  - Toolchain (bun install, tsc, bun test)                      │
│  - tsconfig authorship                                          │
│  - Package.json merge (runtime deps only in integration mode)  │
└─────────────────────────────────────────────────────────────────┘
```

The split is intentional and strict: **hub-codegen is a dumb generator**. It encodes nothing about which package manager to use, how to run tests, or what the host project looks like. synapse-cc encodes all of that.

---

## Generation Pipeline

```
synapse-cc typescript <backend> [options]
    │
    ├─ 1. IR generation
    │      synapse generate-ir → ~/.cache/plexus-codegen/synapse/ir/<backend>/ir.json
    │
    ├─ 2. Code generation
    │      hub-codegen --target typescript --output-format json --transport ws|browser <ir.json>
    │      → stdout: CodegenOutput { files, fileHashes, dependencies, devDependencies, warnings, version }
    │
    ├─ 3. Three-way merge (Merge.hs)
    │      For each file in CodegenOutput.files:
    │        cached_hash = synapse-cc code cache manifest (previous run)
    │        current_hash = SHA-256(on-disk file)[..16]
    │        new_hash = CodegenOutput.fileHashes[file]
    │        if cached_hash == current_hash → safe to update → write new file
    │        if cached_hash != current_hash → user-modified → skip (unless --force)
    │
    ├─ 4. tsconfig.json
    │      Written by synapse-cc (not hub-codegen's version).
    │      include: ["*.ts"] — tsc never sees test/ files.
    │      Browser transport → lib: ["ES2022", "DOM"]
    │      WS transport      → types: ["node"]
    │
    ├─ 5. Package.json merge
    │      Runtime deps from CodegenOutput.dependencies → bun add
    │      Dev deps from CodegenOutput.devDependencies  → bun add -D (standalone only)
    │      Integration mode: devDeps suppressed (host project owns tooling)
    │
    ├─ 6. Toolchain
    │      bun install, bun x tsc --noEmit, bun test
    │
    └─ 7. Cache write
           ~/.cache/plexus-codegen/synapse-cc/code/<target>/<backend>/manifest.json
```

---

## Transport Modes

Configured via `--transport ws|browser` (synapse-cc) which passes `--transport ws|browser|none` to hub-codegen.

| Mode | transport.ts emitted | ws import | ws npm dep | Use case |
|------|---------------------|-----------|------------|----------|
| `ws` (default) | Yes | `import WebSocket from 'ws'` | `"ws": "^8.18.0"` | Node.js, test runners |
| `browser` | Yes | (none) | (none) | Tauri, WebView, Bun native WS |
| `none` | No | (none) | (none) | Monorepo; consumer uses `workspace:*` |

The browser/ws distinction exists because Tauri apps run in a native WebView with `window.WebSocket` available globally. The `ws` Node.js package is unnecessary and its import would break the build.

---

## Deployment Modes

### Standalone
```
synapse-cc typescript substrate -P 4444
```
- Output dir is the project root
- synapse-cc writes tsconfig.json, package.json, transport.ts, rpc.ts, plugin clients
- `bun install`, `tsc`, `bun test` all run in that dir

### Integration (Tauri / host project)
```
synapse-cc typescript substrate -P 4444 -o src/lib/plexus --transport browser
```
- Output dir is a subdirectory of the host project
- Hub-codegen's tsconfig.json is filtered out; synapse-cc writes none either
- Dev deps suppressed — host project owns its own toolchain
- Only runtime deps (e.g. `ws` for ws transport; none for browser) are added to host package.json
- Scaffolding files (test/ directory) are filtered

---

## Cache Architecture

There are **two separate, non-interoperable caches**:

### hub-codegen cache (`src/cache.rs`)
- Location: `~/.cache/plexus-codegen/hub-codegen/<target>/<backend>/manifest.json`
- Active only in `--output-format files` mode (direct CLI use)
- **Completely bypassed** when synapse-cc calls hub-codegen with `--output-format json`

### synapse-cc cache (`src/SynapseCC/Cache.hs`)
- Two manifests:
  - IR cache: `~/.cache/plexus-codegen/synapse/ir/<backend>/manifest.json`
  - Code cache: `~/.cache/plexus-codegen/synapse-cc/code/<target>/<backend>/manifest.json`
- Granular per-plugin invalidation using V2 `self_hash`/`children_hash`
- Transitive dependency invalidation via `SynapseCC.Dependency`
- **This is the active cache in the orchestration pipeline**

The synapse-cc code cache manifest stores per-plugin `fileHashes` sourced from `CodegenOutput.fileHashes` (i.e. the hashes hub-codegen computed over the generated content). These hashes drive the three-way merge on subsequent runs.

---

## Key Invariants

1. **User edits are never silently overwritten.** Three-way merge detects modification via hash comparison. Only `--force` bypasses this.

2. **hub-codegen is stateless in JSON mode.** No disk reads or writes. Idempotent over identical IR.

3. **tsconfig.json is always synapse-cc's.** Hub-codegen's tsconfig is always filtered from the merge, ensuring `include: ["*.ts"]` (no test/ exposure to tsc).

4. **Integration mode does not pollute host devDeps.** `bun-types`, `typescript`, etc. are never injected into a host project's package.json.

5. **Browser transport never imports `ws`.** The generated transport.ts uses only the global `WebSocket` constructor.

---

## Testing

| Suite | Count | What it covers |
|-------|-------|----------------|
| hub-codegen (`cargo test`) | 38 | Transport dispatch correctness, three-way merge logic, cache hit/miss, generated code shape |
| synapse-cc (`cabal test`) | 69 | Full pipeline integration against live substrate: CLI parsing, IR gen, code gen, merge invariants, tsconfig, package.json, toolchain, performance |
| orcha-maestro (`bun test`) | 16 | Generated browser-transport client against live substrate: health, echo, registry (streaming), cone, concurrency |

### Known gaps

- `--output-format files` path in hub-codegen has no unit tests
- `--transport none` (monorepo mode) has no synapse-cc integration test
- synapse-cc integration mode (Tauri) has no automated test; only manually verified via orcha-maestro
- synapse-cc `Cache.hs` V2 transitive invalidation has no direct tests
- All live-substrate tests require substrate at `127.0.0.1:4444`
