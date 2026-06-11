# synapse-cc

**Unified compiler toolchain for Plexus backends**

`synapse-cc` (synapse compiler collection) orchestrates the complete pipeline from backend schema discovery to compiled, ready-to-use client libraries.

## Features

- 🔧 **Unified Interface**: Single command to generate clients from any backend
- 🔍 **Smart Tool Discovery**: Finds local development builds or installed versions
- ⚡ **Fast**: Incremental caching skips regeneration when schemas haven't changed (IR cache at `~/.cache/plexus-codegen/synapse/ir/`, per-file code cache via hub-codegen)
- 🎯 **Multi-Language**: TypeScript and Rust today (`rust` requires a hub-codegen built with `--features rust`); `python` parses but has no generator yet
- 🛠️ **Complete Pipeline**: schema → IR → generated code → installed deps → compiled artifact → smoke tests
- 🔐 **Credential lifecycle**: Per-backend defaults store shared with `synapse` — set, inspect, and rotate JWTs / cookies / headers via `synapse-cc _self <backend> …`. Values held as reference URIs (`literal:`, `env://`, `file://`, `keychain://`) so secrets live in the OS keychain or env vars, not plaintext. JWT decoding flags expired tokens at a glance.

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

The CLI is subcommand-shaped:

```bash
synapse-cc init [BACKEND]                  # scaffold synapse.config.json
synapse-cc build                           # build every target in synapse.config.json
synapse-cc build TARGET BACKEND [OPTIONS]  # one-off build, no config file
synapse-cc watch BACKEND [PLUGIN...]       # rebuild on schema changes
synapse-cc wait [BACKEND]                  # block until backend(s) reachable
synapse-cc _self BACKEND VERB ...          # credentials store (shared with synapse)
```

### Quickstart (config-driven)

A service scaffolded by `axon new` ships a `synapse.config.json` pre-pointed
at itself — `synapse-cc build` works unedited from the service directory
(server must be running). Real run:

```
$ synapse-cc build
==> Discovering tools...
[+] Found all required tools
[i] Building "client" → src/lib/plexus

==> Reading schema...
[+] Schema ready (2 plugins)

==> Generating code...
[+] Code generated (11 files)

==> Installing dependencies...
[+] Dependencies installed

==> Building...
[+] Build passed

==> Running tests...
[+] Tests passed
[+] client → src/lib/plexus/
```

Without a config file, `synapse-cc init <backend>` scaffolds one; with the
backend argument omitted it is **inferred** — from a co-located Plexus
service crate, then from the local registry — and the inference is
announced. There is no silent default backend:

```
$ synapse-cc init
[!] missing BACKEND argument — no co-located Plexus service crate found and
    no backend discoverable on the registry at 127.0.0.1:4444.
    Run: synapse-cc init <backend>
```

### Quickstart (one-off, no config)

```bash
synapse-cc build typescript substrate          # TS client → ./generated/
synapse-cc build rust substrate -o ./client    # Rust client, ends in cargo build
```

The backend is resolved **by name via the registry** (endpoint from
`PLEXUS_REGISTRY_URL`, default `ws://127.0.0.1:4444`; `-H`/`-P` set the
fallback). A real `rust` run:

```
$ synapse-cc build rust zechodev -o ./rust-client
==> Discovering tools...
[+] Found all required tools

==> Resolving zechodev via registry at ws://127.0.0.1:4444...

==> Reading schema...
[+] Schema ready (2 plugins)

==> Generating code...
[+] Code generated (5 files)

==> Building...
[+] Build passed

==> Running tests...
[+] Tests passed

[+] Client → ./rust-client/
```

`-t rust` ends in a real `cargo build` of the generated crate (Z2H-7) — the
artifact compiles or the command fails.

### Options (build / watch)

```
  -o, --output DIR        Output directory (default: ./generated)
  --transport ws|browser  ws (Node.js, default) or browser (native WebSocket,
                          for Tauri/WebView)
  --no-install            Skip dependency installation
  --no-build              Skip compilation step
  --no-tests              Skip running smoke tests
  --cache-dir DIR         Cache directory (default: ~/.cache/plexus-codegen)
  --force                 Force regeneration (ignore cache)
  --debug                 Enable debug logging
  --synapse PATH          synapse binary path (overrides discovery)
  --hub-codegen PATH      hub-codegen binary path (overrides discovery)
  -t, --token JWT         JWT auth token (see Credentials below)
  --token-file PATH       Read JWT from file
  -H, --host HOST         Registry/discovery host (default: 127.0.0.1)
  -P, --port PORT         Registry/discovery port (default: 4444)
```

### Rust target prerequisite

`build rust` requires a hub-codegen binary compiled with the `rust` feature
(`cargo build --release --features all` in the hub-codegen repo). A
typescript-only binary fails with:

```
[!] Error: hub-codegen failed (exit code 1)
Error: Rust codegen not enabled. Rebuild with --features rust
```

Point `--hub-codegen` at a rust-enabled build if the discovered one is not.

### Credentials & Headers

synapse-cc shares a **single defaults store** with synapse at `~/.plexus/<backend>/defaults.json`. Any JWT, cookie, or header you set via either CLI is immediately visible to the other. The file holds credential-reference URIs (`literal:`, `env://`, `file://`, `keychain://`), resolved at request time.

```bash
# Inspect what's stored + decode any JWTs + flag expired tokens
synapse-cc _self <backend> show

# Store a JWT (auto-wrapped as literal:)
synapse-cc _self <backend> set cookie access_token "eyJ..."

# Store a reference to an env var (preferred in CI)
synapse-cc _self <backend> set cookie access_token "env://MY_JWT"

# Import a JWT file
synapse-cc _self <backend> import-token ~/Downloads/jwt.txt

# Clear all defaults for a backend
synapse-cc _self <backend> clear --yes
```

The `_self` subcommand tree is identical to `synapse _self <backend> …` — they share the same library implementation. See synapse's README for the full verb list, URI scheme reference, and legacy `~/.plexus/tokens/<backend>` migration behavior.

Per-invocation overrides: `--token <jwt>`, `SYNAPSE_TOKEN` env, `--token-file <path>`, `--cookie KEY=VALUE`, `--header KEY=VALUE` — all flow through the same priority chain as synapse, with CLI values winning over stored defaults per key.

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
├── app/
│   └── Main.hs              # Entry point, subcommand dispatch
└── src/
    └── SynapseCC/
        ├── Types.hs           # Core types, Options, synapse.config.json types
        ├── CLI.hs             # Subcommand + option parsing
        ├── Config.hs          # synapse.config.json load/init
        ├── Detect.hs          # Project detection for `init` inference
        ├── Discover.hs        # Tool discovery (synapse, hub-codegen)
        ├── RegistryResolve.hs # Backend-name resolution via the registry
        ├── Pipeline.hs        # Pipeline orchestration
        ├── Process.hs         # Subprocess helpers
        ├── Cache.hs           # Incremental IR caching
        ├── Merge.hs           # Three-way merge bookkeeping
        ├── Dependency.hs      # Plugin dependency resolution
        ├── Language.hs        # Per-language install/build/test steps
        ├── Auth.hs            # Token priority chain (wraps Synapse.Self)
        ├── Watch.hs           # watch subcommand
        ├── Wait.hs            # wait subcommand
        └── Logging.hs         # Pretty output
```

### Building

```bash
cabal build
```

### Running from source

```bash
cabal run synapse-cc -- build typescript substrate --debug
```

### Testing

```bash
# Scaffold and start a throwaway backend (any free port)
axon new mysvc --port 4452 && cd mysvc && cargo run &

# Generate, compile, and smoke-test a client against it — the scaffold's
# synapse.config.json is already pointed at ws://127.0.0.1:4452
synapse-cc build
```

## Status

Shipped: tool discovery, pipeline orchestration, config-driven multi-target
builds (`synapse.config.json`), incremental IR + code caching with three-way
merge, dependency installation + compile + smoke-test steps (bun/npm for
TypeScript, cargo for Rust), watch mode, `wait`, registry-based backend
resolution (`PLEXUS_REGISTRY_URL`), shared credentials store (`_self`).

Not shipped: a `python` generator (the target parses; hub-codegen has no
emitter), remote/distributed caching.

## Contributing

See [PLAN.md](./PLAN.md) for detailed implementation plan and design decisions.

## License

MIT
