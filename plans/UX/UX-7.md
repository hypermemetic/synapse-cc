# UX-7: Cross-Platform Discovery Paths

blocked_by: []
unlocks: [UX-9]

## Problem

Dev build discovery paths in `Discover.hs` are hardcoded for Linux:

```haskell
"../synapse/dist-newstyle/build/aarch64-linux/ghc-9.4.8/..."
"../synapse/dist-newstyle/build/x86_64-linux/ghc-9.4.8/..."
```

On macOS (aarch64-osx), neither matches. Discovery only works because synapse is installed via `cabal install` to `~/.cabal/bin/`.

## Scope

Replace hardcoded arch/os/ghc paths with a glob-based search:

```haskell
findInDistNewstyle :: FilePath -> String -> String -> IO (Maybe FilePath)
findInDistNewstyle base package exe = do
  -- Search: base/dist-newstyle/build/*/ghc-*/package-*/x/exe/build/exe/exe
  -- Use System.Directory.findFile or a simple glob
```

Or use `find` as a fallback:
```haskell
-- Look for the executable anywhere under dist-newstyle
candidates <- listDirectoryRecursive (base </> "dist-newstyle")
```

Keep it simple — just glob `dist-newstyle/build/*/ghc-*/<pkg>-*/x/<exe>/build/<exe>/<exe>` and take the first match (or newest by mtime).

## Acceptance Criteria

- `synapse` found from `../synapse/dist-newstyle/` on macOS (aarch64-osx)
- `hub-codegen` found from `../hub-codegen/target/{release,debug}/` (already works)
- No hardcoded architecture or GHC version strings
- PATH fallback still works as before
