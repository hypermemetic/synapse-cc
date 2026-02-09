# synapse-cc

**Unified compiler toolchain for Plexus backends**

`synapse-cc` (synapse compiler collection) orchestrates the complete pipeline from backend schema discovery to compiled, ready-to-use client libraries.

## Features

- 🔧 **Unified Interface**: Single command to generate clients from any backend
- 🔍 **Smart Tool Discovery**: Finds local development builds or installed versions
- ⚡ **Fast**: Smart caching avoids regeneration when schemas haven't changed (coming in Phase 3)
- 🎯 **Multi-Language**: TypeScript, Python, Rust support (TypeScript in MVP)
- 🛠️ **Complete Pipeline**: From schema → IR → generated code → compiled artifacts

## Installation

### From Source

```bash
cd synapse-cc
cabal build
cabal install
```

### Dependencies

`synapse-cc` requires these tools to be available:
- **synapse** - Schema discovery and IR generation
- **hub-codegen** - Code generation from IR

The tool will automatically find them if they're:
- In your `$PATH`
- In local development directories (`../synapse`, `../hub-codegen`)
- In `~/.plexus/bin/`

## Usage

### Basic TypeScript Client

```bash
synapse-cc typescript substrate ws://localhost:4444
```

This will:
1. Connect to substrate at `ws://localhost:4444`
2. Discover the schema
3. Generate IR
4. Generate TypeScript client
5. Output to `./generated/`

### Options

```bash
synapse-cc <target> <backend> <url> [OPTIONS]

Arguments:
  target    Target language (typescript, python, rust)
  backend   Backend identifier (substrate, plexus, synapse, etc.)
  url       Backend WebSocket URL (e.g., ws://localhost:4444)

Options:
  -o, --output DIR           Output directory (default: ./generated)
  --bundle-transport BOOL    Bundle transport code (default: true)
  --no-install              Skip dependency installation
  --no-build                Skip compilation step
  --cache-dir DIR           Cache directory (default: ~/.plexus/cache)
  --force                   Force regeneration (ignore cache)
  --watch                   Watch backend and regenerate on changes
  --debug                   Enable debug logging
  -h, --help                Show help message
```

### Examples

**External transport mode** (uses `@plexus/rpc-client` package):
```bash
synapse-cc typescript substrate ws://localhost:4444 \
  --bundle-transport=false \
  --output ./packages/substrate-client
```

**Skip build steps** (just generate code):
```bash
synapse-cc typescript substrate ws://localhost:4444 \
  --no-install \
  --no-build
```

**Debug mode**:
```bash
synapse-cc typescript substrate ws://localhost:4444 --debug
```

## Architecture

```
synapse-cc (Haskell)
    ↓
    ├─→ synapse (Haskell) → IR (JSON)
    ↓
    ├─→ hub-codegen (Rust) → Generated Code
    ↓
    └─→ Language Tools (npm, tsc, etc.) → Compiled Artifact
```

## Development

### Project Structure

```
synapse-cc/
├── synapse-cc.cabal         # Cabal project file
├── PLAN.md                  # Detailed implementation plan
├── app/
│   └── Main.hs              # Entry point
└── src/
    └── SynapseCC/
        ├── Types.hs         # Core types
        ├── CLI.hs           # Command-line parsing
        ├── Discover.hs      # Tool discovery
        ├── Pipeline.hs      # Pipeline orchestration
        ├── Process.hs       # Subprocess helpers
        ├── Cache.hs         # Caching (Phase 3)
        ├── Language.hs      # Language integration (Phase 2)
        └── Logging.hs       # Pretty output
```

### Building

```bash
cabal build
```

### Running from source

```bash
cabal run synapse-cc -- typescript substrate ws://localhost:4444
```

### Testing

```bash
# Ensure substrate is running
cd ../plexus-substrate
cargo run -- --port 4444

# In another terminal, test synapse-cc
cd ../synapse-cc
cabal run synapse-cc -- typescript substrate ws://localhost:4444 --debug
```

## Roadmap

### Phase 1: MVP (Current)
- ✅ Project scaffolding
- ✅ Tool discovery
- ✅ Pipeline orchestration
- ✅ Basic error handling
- [ ] End-to-end testing

### Phase 2: Language Integration
- [ ] Dependency installation (npm, pip, cargo)
- [ ] Build automation
- [ ] Multi-package manager support

### Phase 3: Smart Caching
- [ ] Hash-based caching
- [ ] Cache management
- [ ] Fast iteration

### Phase 4: Production Features
- [ ] Watch mode
- [ ] Progress indicators
- [ ] Auto-install tools
- [ ] Configuration files

## Contributing

See [PLAN.md](./PLAN.md) for detailed implementation plan and design decisions.

## License

MIT
