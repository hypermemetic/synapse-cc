# synapse-cc Development Guide

## Architecture Documentation Naming Convention

Architecture documents in `docs/architecture/` use reverse-chronological naming to ensure newest documents appear first in alphabetical sorting.

**Naming formula**: `(u64::MAX - nanotime)_title.md`

Where:
- `nanotime` = current Unix timestamp in nanoseconds
- This creates a descending numeric prefix (newer = smaller number = sorts first)
- Example: `16675916618081268991_incremental-caching-system.md`

**To generate a filename**:
```python
import time
nanotime = int(time.time() * 1_000_000_000)
filename = (2**64 - 1) - nanotime
print(f'{filename}_your-title.md')
```

This "chronological bubbling" helps prioritize recent architectural decisions.

---

## Key Architecture Documents

- **Incremental Caching System** (`docs/architecture/16675916618081268991_incremental-caching-system.md`): Complete architecture for the incremental caching system with three-way merge conflict detection. Covers cache manifests, hash computation, merge strategies, performance metrics, and integration between synapse-cc (Haskell) and hub-codegen (Rust). Production ready with 100% test coverage.

---

## Project Structure

```
synapse-cc/
├── app/                    # Executable entry point
│   └── Main.hs
├── src/                    # Library source
│   └── SynapseCC/
│       ├── Auth.hs            # Token priority chain (wraps Synapse.Self)
│       ├── AuthCheck.hs       # Pre-flight auth validation
│       ├── Benchmark.hs       # Timing instrumentation
│       ├── Cache.hs           # IR cache management
│       ├── CLI.hs             # Subcommand + option parsing
│       ├── Config.hs          # synapse.config.json load/init
│       ├── Dependency.hs      # Plugin dependency resolution
│       ├── Detect.hs          # Project detection for `init` inference
│       ├── Discover.hs        # Tool discovery (synapse, hub-codegen)
│       ├── Language.hs        # Per-language install/build/test steps
│       ├── Lock.hs            # Concurrency lock for cache writes
│       ├── Logging.hs         # Colored output and logging
│       ├── Merge.hs           # Three-way merge bookkeeping
│       ├── Pipeline.hs        # Main orchestration pipeline
│       ├── Process.hs         # Subprocess execution
│       ├── RegistryResolve.hs # Backend-name resolution via registry
│       ├── Types.hs           # Core types and errors
│       ├── Wait.hs            # wait subcommand
│       └── Watch.hs           # watch subcommand
├── test/                   # Test suite
│   └── Main.hs
├── docs/
│   └── architecture/       # Architecture documents
└── synapse-cc.cabal        # Cabal package definition
```

---

## synapse-cc Architecture

synapse-cc is the **unified compiler toolchain** that orchestrates the complete pipeline from Plexus RPC backend schema discovery to compiled, ready-to-use client libraries.

### Pipeline Flow

```
1. Tool Discovery
   ↓ Finds synapse and hub-codegen binaries

2. Resolve Backend
   ↓ By name via the registry (PLEXUS_REGISTRY_URL, default
   ↓ ws://127.0.0.1:4444; -H/-P set the fallback endpoint)

3. Generate IR
   ↓ Via the plexus-synapse library (in-process)
   ↓ Writes: ~/.cache/plexus-codegen/synapse/ir/<backend>/ir.json
   ↓         ~/.cache/plexus-codegen/synapse/ir/<backend>/manifest.json

4. Generate Code
   ↓ Calls: hub-codegen <ir.json> -o <output> -t <target>
   ↓ Reads: ~/.cache/plexus-codegen/hub-codegen/<target>/<backend>/manifest.json
   ↓ Three-way merge with conflict detection
   ↓ Writes: ~/.cache/plexus-codegen/hub-codegen/<target>/<backend>/manifest.json

5. Install + Compile
   ↓ typescript: bun/npm install + build; rust: cargo build (Z2H-7)
   ↓ Skip with --no-install / --no-build

6. Run Tests
   ↓ Smoke tests for the generated client; skip with --no-tests
```

### Key Design Decisions

**1. Hybrid: subprocess for hub-codegen, library for synapse**

`hub-codegen` is a separate Rust binary called as a subprocess — discovered in standard locations, communicated with via CLI arguments and JSON files. Independent development cycles, language flexibility.

`synapse` is consumed as a **Haskell library** (`plexus-synapse` in `build-depends`; `cabal.project` lists `../synapse` as a local package). synapse-cc imports `Synapse.Monad`, `Synapse.IR.Builder`, `Synapse.Log`, `Synapse.Backend.Discovery`, and `Synapse.Self` directly. This lets the two tools share the credentials store (`Synapse.Self`) and `_self` subcommand handlers without reinventing them. See "Credentials store" below.

**2. Two-Level Caching**

- **IR Cache** (`~/.cache/plexus-codegen/synapse/ir/`): Managed by synapse-cc
  - Tracks schema hashes from Plexus RPC backend
  - Detects when backend schema changes
  - Avoids redundant IR generation

- **Code Cache** (`~/.cache/plexus-codegen/hub-codegen/`): Managed by hub-codegen
  - Tracks generated file hashes
  - Detects user modifications via three-way merge
  - Preserves user code by default

**3. Cache Key Consistency**

Critical: synapse-cc and hub-codegen must use the same plugin key.

```haskell
-- synapse-cc writes cache with key "default"
Map.singleton "default" CodePluginCache

-- hub-codegen reads cache with key "default"
manifest.plugins.get("default")  // Must match!
```

**Bug**: Previous mismatch ("all" vs "default") caused conflict detection to fail.

---

## Tool Discovery

**Location**: `src/SynapseCC/Discover.hs`

synapse-cc searches for tools in priority order:

### synapse binary

```haskell
synapsePaths home =
  [ -- Relative development builds
    "../synapse/dist-newstyle/build/.../synapse"
  , "../../synapse/dist-newstyle/build/.../synapse"
    -- User installations
  , home </> ".plexus/bin/synapse"
  , home </> ".local/bin/synapse"
  , home </> ".cabal/bin/synapse"
  ]
```

### hub-codegen binary

```haskell
hubCodegenPaths home =
  [ -- Relative development builds
    "../hub-codegen/target/release/hub-codegen"
  , "../../hub-codegen/target/release/hub-codegen"
    -- User installations
  , home </> ".plexus/bin/hub-codegen"
  , home </> ".local/bin/hub-codegen"
  , home </> ".cargo/bin/hub-codegen"
  ]
```

### Error Messages

If a tool is not found, synapse-cc provides helpful suggestions:

```
Error: synapse not found

Suggestions:
  - Build synapse: cd ../synapse && cabal build
  - Install synapse: cabal install synapse
  - Add to PATH: export PATH="$HOME/.cabal/bin:$PATH"
```

---

## Credentials store

Both synapse and synapse-cc share a per-backend defaults store at `~/.plexus/<backend>/defaults.json`. The file holds **credential-reference URIs** (`literal:`, `env://`, `file://`, `keychain://`); the actual secret material is never inlined unless the URI is `literal:`.

**Shared implementation:** `Synapse.Self` in the `plexus-synapse` library. synapse-cc imports it directly — there's no duplicated resolver logic. `SynapseCC.Auth.resolveToken` is a thin CLI-priority-chain wrapper (`--token` > `SYNAPSE_TOKEN` > `--token-file` > stored defaults); its final fallback calls `Synapse.Self.resolveToken`.

**`_self` subcommand:** `synapse-cc _self <backend> <verb>` dispatches to `Synapse.Self.Command.runSelfCommand` — the identical handler that `synapse _self` uses. Both CLIs see the same file, produce the same output. Users can set credentials via either.

**Verbs** (see synapse/README.md for the full reference):
- `show` — inspects state, decodes JWTs, flags expired tokens, shows OIDC login status/tenant
- `set cookie|header <name> <value-or-uri>` — auto-wraps bare values as `literal:`
- `set-from-stdin cookie|header <name>` — explicit literal, bypasses scheme heuristic
- `unset`, `clear`, `resolve`, `import-token`
- `login` / `logout` / `refresh` / `tenant` — OIDC login lifecycle (UT-3); expired access tokens are transparently refreshed via the stored refresh token on ordinary invocations

**Legacy migration:** on first read of a backend that has `~/.plexus/tokens/<backend>` (pre-SELF convention) but no `defaults.json`, `Synapse.Self.loadDefaults` auto-migrates the JWT as `cookies.access_token = literal:<jwt>` and deletes the legacy file. Emits an INFO log naming both paths.

**File permissions:** `writeDefaults` applies content-aware chmod — `0600` when the file contains any `literal:` value, `0644` otherwise. Parent directory mode `0700` when freshly created.

**Keychain status:** `keychain://` **reads** resolve on macOS (shell-out to the `security` CLI; Linux/Windows return a clear not-implemented error). The **write** verbs — `set-secret`, `upgrade-to-keychain`, `import-token --to-keychain` — are stubbed with a friendly "requires SELF-8" error. The store is fully functional via `literal:`, `env://`, `file://` today.

Related tickets (all Complete except SELF-8): `synapse/plans/SELF/SELF-1..8.md`.

---

## Cache Management

### IR Cache Manifest

**Location**: `~/.cache/plexus-codegen/synapse/ir/<backend>/manifest.json`
(the cached IR itself sits next to it as `ir.json`)

**Structure** (from `src/SynapseCC/Types.hs`):
```haskell
data IRCacheManifest = IRCacheManifest
  { ircmVersion    :: !Text
  , ircmIRVersion  :: !Text
  , ircmToolchain  :: !ToolchainVersions
  , ircmUpdatedAt  :: !Text
  , ircmPlugins    :: !(Map Text IRPluginCache)
  }

data IRPluginCache = IRPluginCache
  { ipcIRHash       :: !Text   -- Hash of the generated IR for this plugin
  , ipcSchemaHash   :: !Text   -- Hash of the source schema (composite)
  , ipcSelfHash     :: !Text   -- V2: methods-only hash (granular invalidation)
  , ipcChildrenHash :: !Text   -- V2: children-only hash (granular invalidation)
  , ipcDependencies :: ![Text]
  , ipcCachedAt     :: !Text
  }
```

**Purpose**: Tracks when IR needs regeneration due to:
- Backend schema changes (`schemaHash` changed)
- synapse version changes
- synapse-cc version changes

### Code Cache Manifest

**Location**: `~/.cache/plexus-codegen/hub-codegen/<target>/<backend>/manifest.json`

**Managed by**: hub-codegen (Rust)

**Purpose**: Tracks generated file hashes for conflict detection

See `docs/architecture/16675916618081268991_incremental-caching-system.md` for details.

---

## Cache Invalidation

### When to Regenerate IR?

```haskell
-- From src/SynapseCC/Cache.hs
validateIRCache :: IRCacheManifest -> IO CacheStatus
validateIRCache manifest = do
  -- Check tool versions
  if tvSynapseCC toolchain /= currentVersion ||
     tvSynapse toolchain /= currentVersion
    then return CacheMiss_ToolchainChanged

  -- Check schema hash
  freshSchemaHash <- fetchSchemaFromBackend
  if ipcSchemaHash cache /= freshSchemaHash
    then return CacheMiss_SchemaChanged

  -- Check IR hash
  if ipcIRHash cache != freshIRHash
    then return CacheMiss_IRChanged

  return CacheHit
```

### When to Regenerate Code?

Handled by hub-codegen via three-way merge. See architecture doc for details.

---

## Error Handling

synapse-cc provides clear error messages for all failure modes:

```haskell
data SynapseCCError
  = ToolNotFound !Text ![Text]          -- Tool name + suggestions
  | SynapseFailed !Int !Text            -- Exit code + stderr
  | HubCodegenFailed !Int !Text         -- Exit code + stderr
  | IRCacheCorrupted !Text              -- Error message
  | CodeCacheCorrupted !Text            -- Error message
  | InvalidConfig !Text                 -- Configuration error
```

**Example output**:
```
Error: synapse failed (exit code 1)

  Could not connect to backend at localhost:4444

  Suggestions:
    - Check that the backend is running
    - Verify the host and port: -H localhost -P 4444
    - Try: plexus-substrate --port 4444
```

---

## Development Workflow

### Building

```bash
cd synapse-cc
cabal build

# Run tests
cabal test

# Install locally
cabal install
```

### Testing with Development Builds

synapse-cc automatically finds development builds:

```bash
# From synapse-cc directory (note the `build` subcommand — the old
# subcommand-less form `synapse-cc typescript substrate` no longer parses)
cabal run synapse-cc -- build typescript substrate -o /tmp/client

# Finds:
#   ../synapse/dist-newstyle/build/.../synapse
#   ../hub-codegen/target/release/hub-codegen
```

### Debugging

**Enable debug output**:
```bash
synapse-cc build typescript substrate -o /tmp/client --debug
```

**Check cache status**:
```bash
# View IR cache
cat ~/.cache/plexus-codegen/synapse/ir/substrate/manifest.json | jq

# View code cache
cat ~/.cache/plexus-codegen/hub-codegen/typescript/substrate/manifest.json | jq
```

**Clear caches** (both live under the same root):
```bash
rm -rf ~/.cache/plexus-codegen/
```

---

## Integration with Other Tools

### synapse (Haskell CLI)

**Repository**: `/workspace/hypermemetic/synapse/`

**Purpose**: Connects to Plexus RPC backends and generates IR JSON

**Consumed by synapse-cc as a library** (`plexus-synapse` in `build-depends`;
IR is built in-process via `Synapse.IR.Builder`). The equivalent standalone
invocation, useful for debugging what synapse-cc sees:
```bash
synapse --emit-ir -P 4444 substrate --generator-info synapse-cc:<version>
```

**Output**: IR JSON file

### hub-codegen (Rust CLI)

**Repository**: `/workspace/hypermemetic/hub-codegen/`

**Purpose**: Generates TypeScript/Rust client code from IR

**Called by synapse-cc**:
```bash
hub-codegen /tmp/ir.json -o ./client -t typescript --merge-strategy skip
```

**Features**:
- Three-way merge with conflict detection
- Content-based caching
- Per-file hash tracking
- User code preservation

---

## Testing

### Unit Tests

```bash
cabal test
```

**Location**: `test/Main.hs`

**Coverage**:
- Cache manifest serialization
- Tool discovery
- Error handling
- Version validation

### Integration Tests

**Manual testing workflow**:

```bash
# 1. Start a Plexus RPC backend (axon scaffold works; any free port)
axon new mysvc --port 4452 && cd mysvc && cargo run

# 2. Generate client code (from the scaffold dir, config-driven)
synapse-cc build
#    …or one-off: cabal run synapse-cc -- build typescript mysvc -o /tmp/client

# 3. Verify output
cat ~/.cache/plexus-codegen/synapse/ir/mysvc/manifest.json | jq
cat ~/.cache/plexus-codegen/hub-codegen/typescript/mysvc/manifest.json | jq

# 4. Test cache hit
synapse-cc build
# Should be very fast (cache hit)

# 5. Test conflict detection
echo "// USER CODE" >> src/lib/plexus/greeter/types.ts
synapse-cc build
# Should show warning about modified file
```

---

## Performance

### Benchmarks

**Cold cache** (first run):
- Tool discovery: ~5ms
- IR generation: ~500ms (depends on backend)
- Code generation: ~200ms
- Total: ~705ms

**Hot cache** (no changes):
- Tool discovery: ~5ms
- IR cache hit: ~1ms
- Code cache hit: ~50ms (97.7% hit rate)
- Total: ~56ms
- **Speedup: 12.6x**

**With user modifications**:
- Tool discovery: ~5ms
- IR cache hit: ~1ms
- Three-way merge: ~50ms
- User code preserved: ✅
- Total: ~56ms
- **Speedup: 12.6x**

---

## Future Work

See `docs/architecture/16675916618081268991_incremental-caching-system.md` for details:

1. **Interactive Merge Mode**: User prompts for conflict resolution
2. **Python generator**: the `python` target parses but hub-codegen has no emitter
3. **Remote Cache**: S3/GCS backend for distributed teams

Already shipped (formerly listed here as future): V2 granular hashing
(`ipcSelfHash` / `ipcChildrenHash`), the compile step (bun/npm + cargo, Z2H-7),
smoke tests, and watch mode (`synapse-cc watch`).

---

## Troubleshooting

### "Tool not found" errors

**Check search paths**:
```bash
ls ../synapse/dist-newstyle/build/*/ghc-*/plexus-synapse-*/x/synapse/build/synapse/
ls ../hub-codegen/target/release/
ls ~/.plexus/bin/
ls ~/.local/bin/
ls ~/.cabal/bin/
ls ~/.cargo/bin/
```

**Solution**: Build missing tools or install them

### Cache corruption

**Symptoms**: Unexpected cache misses, errors reading manifests

**Solution**:
```bash
rm -rf ~/.cache/plexus-codegen/
```

### Conflict detection not working

**Symptoms**: User modifications being overwritten

**Check cache key consistency**:
```bash
# synapse-cc should write "default" key
cat ~/.cache/plexus-codegen/hub-codegen/typescript/substrate/manifest.json | jq '.plugins | keys'
# Output: ["default"]

# hub-codegen should read "default" key
# (Check src/SynapseCC/Pipeline.hs line 215 and hub-codegen src/main.rs)
```

**If keys don't match**: Update synapse-cc to use "default" consistently

---

## Contributing

When adding features:

1. **Update architecture docs** for significant changes
2. **Follow naming conventions** for new files
3. **Add tests** for new functionality
4. **Update this CLAUDE.md** with new guidance
5. **Consider cache invalidation** when changing types

---

## References

- **Architecture**: `docs/architecture/16675916618081268991_incremental-caching-system.md`
- **synapse**: `/workspace/hypermemetic/synapse/`
- **hub-codegen**: `/workspace/hypermemetic/hub-codegen/`
- **Plexus RPC**: `/workspace/hypermemetic/plexus-substrate/`
