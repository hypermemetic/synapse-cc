# synapse-cc: Unified Compiler Toolchain

## Overview

`synapse-cc` (synapse compiler collection) is a unified toolchain that orchestrates the complete pipeline from backend schema discovery to compiled, ready-to-use client libraries.

## Goals

1. **Unified Interface**: Single command to generate clients from any backend
2. **Tool Discovery**: Find and use local development tools or installed versions
3. **Smart Caching**: Avoid regeneration when schemas haven't changed
4. **Language Integration**: Handle dependency installation and compilation
5. **Developer Experience**: Clear errors, progress indicators, helpful messages

## Architecture

### Tool Chain

```
synapse-cc (Haskell)
    ↓
    ├─→ synapse (Haskell) → IR (JSON)
    ↓
    ├─→ hub-codegen (Rust) → Generated Code
    ↓
    └─→ Language Tools (npm, tsc, etc.) → Compiled Artifact
```

### Command Structure

```bash
synapse-cc <target> <backend> <url> [OPTIONS]

Arguments:
  <target>   Target language (typescript, python, rust, etc.)
  <backend>  Backend identifier (substrate, plexus, synapse, etc.)
  <url>      Backend WebSocket URL (e.g., ws://localhost:4444)

Options:
  -o, --output <DIR>           Output directory (default: ./generated)
  --bundle-transport BOOL      Bundle transport code (default: true)
  --no-install                 Skip dependency installation
  --no-build                   Skip compilation step
  --cache-dir <DIR>            Cache directory (default: ~/.plexus/cache)
  --force                      Force regeneration (ignore cache)
  --watch                      Watch backend and regenerate on changes
  --debug                      Enable debug logging
  -h, --help                   Show help message
```

## Implementation Phases

### Phase 1: MVP Pipeline (Core Functionality)

**Goal**: Working end-to-end pipeline without bells and whistles

**Tasks**:
1. ✅ Project scaffolding (Cabal, module structure)
2. ✅ CLI argument parsing with `optparse-applicative`
3. ✅ Tool discovery system:
   - Check local dev paths
   - Check $PATH
   - Check ~/.plexus/bin/
   - Fail with helpful error
4. ✅ Pipeline orchestration:
   - Run synapse to generate IR
   - Run hub-codegen on IR
   - Write output to directory
5. ✅ Basic error handling and logging
6. ✅ End-to-end test with substrate

**Deliverable**: Command that works for TypeScript generation from substrate

### Phase 2: Language Integration

**Goal**: Handle language-specific tooling automatically

**Tasks**:
1. Detect package manager (npm, pnpm, yarn, cargo, pip, etc.)
2. Run dependency installation
3. Run compilation/build commands
4. Validate output artifacts
5. Handle language-specific errors gracefully

**Deliverable**: Fully compiled, ready-to-use client libraries

### Phase 3: Smart Caching

**Goal**: Only regenerate when necessary

**Tasks**:
1. Read IR hash from generated IR
2. Cache structure in ~/.plexus/cache/
3. Compare schema hashes to detect changes
4. Reuse cached IR and generated code when possible
5. --force flag to bypass cache

**Cache Structure**:
```
~/.plexus/cache/
├── ir/
│   └── <hash>.json              # Cached IR by hash
└── generated/
    └── <hash>/
        ├── typescript/           # Cached TypeScript client
        ├── python/               # Cached Python client
        └── ...
```

**Deliverable**: Near-instant regeneration when schemas unchanged

### Phase 4: Watch Mode & Intelligence

**Goal**: Developer-friendly features

**Tasks**:
1. Watch backend schema for changes (periodic polling)
2. Regenerate automatically on detection
3. Parallel generation for multiple targets
4. Progress indicators and spinners
5. Colorized output
6. Auto-install missing tools (synapse, hub-codegen)

**Deliverable**: Production-ready developer tool

## Module Structure

```
synapse-cc/
├── synapse-cc.cabal
├── PLAN.md                      # This file
├── README.md                    # User-facing documentation
├── app/
│   └── Main.hs                  # Entry point, wires everything together
└── src/
    └── SynapseCC/
        ├── Types.hs             # Core types (Config, Target, Backend, etc.)
        ├── CLI.hs               # Command-line argument parsing
        ├── Discover.hs          # Tool discovery (find synapse, hub-codegen)
        ├── Pipeline.hs          # Pipeline orchestration
        ├── Process.hs           # Subprocess execution helpers
        ├── Cache.hs             # IR/code caching by hash
        ├── Language.hs          # Language-specific integrations
        └── Logging.hs           # Pretty logging and progress indicators
```

## Key Design Decisions

### 1. Subprocess Execution (Not FFI)

**Decision**: Call synapse and hub-codegen as separate processes

**Rationale**:
- Clean separation of concerns
- No need to link Rust into Haskell
- Easier to version tools independently
- Standard Unix philosophy: compose tools
- Each tool can be developed/tested independently

**Implementation**:
```haskell
runSynapse :: Backend -> URL -> FilePath -> IO (Either Error IRPath)
runHubCodegen :: IRPath -> Target -> Options -> FilePath -> IO (Either Error GeneratedPath)
```

### 2. Tool Discovery Strategy

**Priority Order**:
1. Local development paths (for contributors)
   - `../synapse/dist-newstyle/build/.../synapse`
   - `../hub-codegen/target/release/hub-codegen`
2. System PATH (for installed versions)
   - `synapse` and `hub-codegen` in $PATH
3. Plexus bin directory (for managed installs)
   - `~/.plexus/bin/synapse`
   - `~/.plexus/bin/hub-codegen`
4. Fail with helpful installation instructions

**Future**: Auto-install via cabal/cargo

### 3. Caching Strategy

**Key Insight**: IR already has hash field!

```json
{
  "irVersion": "2.0",
  "irBackend": "substrate",
  "irHash": "abc123...",
  ...
}
```

**Cache Key**: `irHash` + `target` + `codegen_options`

**Benefits**:
- Only regenerate when schema actually changes
- Share cache across invocations
- Fast iteration during development

### 4. Error Handling

**Philosophy**: Fail fast with helpful messages

**Examples**:
```
❌ Error: synapse not found

synapse-cc requires synapse to generate IR.

Try:
  • Build synapse: cd ../synapse && cabal build
  • Install synapse: cabal install synapse
  • Add to PATH: export PATH="$PATH:~/.plexus/bin"

For more info: https://github.com/hypermemetic/synapse
```

## Success Metrics

### Phase 1 Success
- [x] Can run: `synapse-cc typescript substrate ws://localhost:4444`
- [x] Generates valid TypeScript client
- [x] Clear error if tools missing
- [x] Works from any directory

### Phase 2 Success
- [ ] Runs `npm install` automatically
- [ ] Compiles TypeScript to JavaScript
- [ ] Handles missing dependencies gracefully
- [ ] Works with multiple package managers

### Phase 3 Success
- [ ] Second run is near-instant (cache hit)
- [ ] Detects schema changes and regenerates
- [ ] --force flag bypasses cache
- [ ] Cache can be cleared

### Phase 4 Success
- [ ] Watch mode works reliably
- [ ] Beautiful progress indicators
- [ ] Can auto-install missing tools
- [ ] Production-ready UX

## Example Usage

### Basic TypeScript Client
```bash
synapse-cc typescript substrate ws://localhost:4444

# Output:
# 🔍 Discovering tools...
# ✓ Found synapse at ../synapse/dist-newstyle/.../synapse
# ✓ Found hub-codegen at ../hub-codegen/target/release/hub-codegen
#
# 📡 Connecting to substrate at ws://localhost:4444...
# ✓ Connected
#
# 🔨 Generating IR...
# ✓ IR generated (hash: abc123...)
#
# 🏗️  Generating TypeScript client...
# ✓ Generated 12 files
#
# 📦 Installing dependencies...
# ✓ npm install completed
#
# 🔧 Compiling TypeScript...
# ✓ Compilation successful
#
# ✅ Client ready at ./generated/
```

### External Transport Mode
```bash
synapse-cc typescript substrate ws://localhost:4444 \
  --bundle-transport=false \
  --output ./packages/substrate-client
```

### Watch Mode (Future)
```bash
synapse-cc typescript substrate ws://localhost:4444 --watch

# Output:
# 👀 Watching substrate for schema changes...
# Press Ctrl+C to stop.
#
# [14:23:45] Schema changed (hash: def456...)
# [14:23:45] Regenerating...
# [14:23:46] ✓ Done
```

## Dependencies

### Haskell Dependencies
- `base >= 4.14`
- `optparse-applicative` - CLI parsing
- `process` - Subprocess execution
- `aeson` - JSON parsing (for IR)
- `bytestring` - Efficient strings
- `text` - Text handling
- `filepath` - Path manipulation
- `directory` - File system operations
- `async` - Concurrency (for watch mode)
- `ansi-terminal` - Colorized output
- `time` - Timestamps
- `cryptohash-sha256` - Cache key hashing

### External Tools (Runtime)
- `synapse` - Schema discovery and IR generation
- `hub-codegen` - Code generation from IR
- Language tools (npm, tsc, cargo, pip, etc.) - Language-specific builds

## Future Extensions

### Multi-Target Generation
```bash
synapse-cc typescript,python,rust substrate ws://localhost:4444
# Generates clients for all three languages in parallel
```

### Configuration File
```yaml
# .synapse-cc.yaml
targets:
  - typescript:
      output: ./packages/ts-client
      bundle_transport: false
  - python:
      output: ./packages/py-client

backends:
  - substrate: ws://localhost:4444
  - plexus: ws://localhost:5000

cache_dir: ./.synapse-cache
watch: true
```

### CI/CD Integration
```bash
synapse-cc check substrate ws://localhost:4444
# Exit 0 if schema unchanged, 1 if changed (for CI)
```

### Schema Diff
```bash
synapse-cc diff substrate ws://localhost:4444
# Shows schema changes since last generation
```

## Testing Strategy

### Unit Tests
- Tool discovery logic
- Cache key generation
- Path resolution
- Error message formatting

### Integration Tests
- End-to-end pipeline with mock backend
- Cache hit/miss scenarios
- Error handling paths

### Manual Tests
- Real substrate backend
- Multiple target languages
- Watch mode stability

## Release Plan

### v0.1.0 - MVP
- Phase 1 complete
- Basic TypeScript generation
- Tool discovery
- No caching, no language integration

### v0.2.0 - Language Integration
- Phase 2 complete
- Dependency installation
- TypeScript compilation
- Multiple package manager support

### v0.3.0 - Smart Caching
- Phase 3 complete
- Hash-based caching
- Fast regeneration
- Cache management commands

### v1.0.0 - Production Ready
- Phase 4 complete
- Watch mode
- Auto-install tools
- Beautiful UX
- Documentation complete
- Battle-tested

## Open Questions

1. **Auto-install strategy**: Use cabal/cargo directly or download prebuilt binaries?
2. **Configuration file format**: YAML, TOML, or JSON?
3. **Watch mode implementation**: Polling interval? inotify?
4. **Multi-target parallelism**: Sequential or parallel generation?
5. **Cache eviction**: Keep last N? Time-based? Manual only?

## Conclusion

`synapse-cc` will become the primary interface for generating clients from Plexus backends. By orchestrating the full toolchain, it dramatically improves developer experience and reduces the barrier to entry for consuming backend APIs.

The phased approach ensures we can deliver value quickly (Phase 1) while building toward a polished, production-ready tool (Phase 4).
