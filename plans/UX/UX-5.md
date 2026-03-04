# UX-5: CLI Flags Cleanup

blocked_by: []
unlocks: [UX-9]

## Problem

1. `--bundle-transport BOOL` requires explicit `True`/`False` argument — unlike every other boolean flag
2. No `--version` / `-V` flag — version only shows in `--debug` output
3. `--watch` flag is accepted but completely ignored (unimplemented)

## Scope

### 1. Fix `--bundle-transport`
Replace `option auto` with a switch pair: `--bundle-transport` (default on) / `--no-bundle-transport`.

```haskell
<*> fmap not (switch
    ( long "no-bundle-transport"
   <> help "Don't bundle transport code"
    ))
```

### 2. Add `--version`
Use optparse-applicative's `simpleVersioner` or `infoOption`:

```haskell
infoOption versionString
  ( long "version"
 <> short 'V'
 <> help "Print version and exit"
  )
```

### 3. Remove `--watch`
Delete `optWatch` from `Options`, remove the flag from the parser. It can be re-added when actually implemented.

## Acceptance Criteria

- `--bundle-transport` is a bare flag (no argument needed)
- `--no-bundle-transport` disables it
- `synapse-cc --version` prints version and exits
- `--watch` is gone from `--help`
