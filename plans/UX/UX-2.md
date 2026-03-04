# UX-2: Fix Broken Defaults

blocked_by: []
unlocks: [UX-9]

## Resolution (COMPLETED — won't do as written)

**Decision**: Keep install, build, and tests **ON by default**. Do not flip them to opt-in switches.

The original plan proposed turning build and tests off by default as a workaround for failures. Instead, fix the underlying issues:

- **Build fails** (`tsc --noEmit` missing `@types/node`): fix hub-codegen to emit `@types/node` in generated `package.json`
- **Tests fail** (`health.check` returns `-32601`): fix the smoke test or the backend to handle health checks correctly

If defaults break, fix the thing that's breaking — don't paper over it by disabling the step.

The `--no-build`, `--no-tests`, `--no-install` flags remain as opt-out escapes for power users.

Also note: `defaultOptions` in `Types.hs` currently has `optRunTests = False` which contradicts the CLI behavior (`flag True False` defaults to True). This should be corrected to `optRunTests = True` to match actual CLI behaviour.

## Original Problem (for reference)

`cabal run -- synapse-cc typescript substrate` failed on default invocation because:

1. **Build step fails**: `tsc --noEmit` errors on missing `@types/node` (not in generated `package.json`)
2. **Test step fails**: smoke test calls `health.check` which returns `-32601 Method not found`
3. **Tests default to ON**: `--no-tests` flag uses `flag True False` (default=True), contradicting `defaultOptions` which sets `optRunTests = False`.
