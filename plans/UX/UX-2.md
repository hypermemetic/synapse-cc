# UX-2: Fix Broken Defaults

blocked_by: []
unlocks: [UX-9]

## Problem

`cabal run -- synapse-cc typescript substrate` fails on default invocation because:

1. **Build step fails**: `tsc --noEmit` errors on missing `@types/node` (not in generated `package.json`)
2. **Test step fails**: smoke test calls `health.check` which returns `-32601 Method not found`
3. **Tests default to ON**: `--no-tests` flag uses `flag True False` (default=True), contradicting `defaultOptions` which sets `optRunTests = False`. The optparse-applicative default wins, so tests run by default.

## Scope

### 1. Default tests to OFF
Change `--no-tests` from `flag True False` to match the `defaultOptions` intent. Tests should be opt-in via `--tests`, not opt-out via `--no-tests`.

**In `CLI.hs`**: Replace the `--no-tests` flag with `--tests` switch:
```haskell
<*> switch
    ( long "tests"
   <> help "Run smoke tests after generation"
    )
```

### 2. Default build to OFF
The build step (`tsc --noEmit`) depends on `@types/node` which hub-codegen doesn't emit. Until that's fixed upstream, default `--no-build` to True.

**In `CLI.hs`**: Replace `--no-build` flag with `--build` switch:
```haskell
<*> switch
    ( long "build"
   <> help "Run type-checking after generation"
    )
```

### 3. Keep `--no-install` as-is
Dependency installation (`pnpm install`) works correctly and should remain on by default.

## Acceptance Criteria

- `cabal run -- synapse-cc typescript substrate` succeeds end-to-end (IR gen → code gen → install → done)
- `--build` opt-in enables `tsc --noEmit`
- `--tests` opt-in enables smoke tests
- `--no-install` still works to skip dependency installation
- Help text reflects new defaults
