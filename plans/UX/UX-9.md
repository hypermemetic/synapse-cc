# UX-9: Update Tests and Documentation

blocked_by: [UX-2, UX-3, UX-4, UX-5, UX-6, UX-7, UX-8]
unlocks: []

## Problem

After all UX changes land, tests and CLAUDE.md will be stale.

## Scope

### 1. Update test/Main.hs
- Update CLI parsing tests for new flag names (`--tests`, `--build`, `--no-bundle-transport`, removed `--watch`)
- Update any tests that reference `ir.json` in the output directory
- Add test for `--version` flag

### 2. Update CLAUDE.md
- Reflect new CLI flags and defaults in the usage section
- Update pipeline flow description
- Remove references to `--watch`
- Update ir.json location

### 3. Update help text
Verify `synapse-cc --help` output is clear and accurate.

## Acceptance Criteria

- `cabal test` passes
- CLAUDE.md matches actual behavior
- `--help` output is accurate
