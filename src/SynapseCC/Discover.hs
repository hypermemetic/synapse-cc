-- | Tool discovery - finding synapse and hub-codegen executables
module SynapseCC.Discover
  ( discoverTools
  , findTool
  , toolPathToFilePath
  , findInDistNewstyle
  ) where

import Control.Exception (catch, SomeException, try)
import System.Exit (ExitCode)
import Control.Monad (forM, when)
import Data.List (sortBy, maximumBy)
import Data.Maybe (catMaybes)
import Data.Ord (comparing, Down(..))
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist, doesDirectoryExist, findExecutable, getHomeDirectory, listDirectory, getModificationTime)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

import SynapseCC.Logging (logDebug, logInfo)
import SynapseCC.Types

-- ============================================================================
-- Tool Discovery
-- ============================================================================

-- | Discover all required tools, respecting any explicit paths in Options
discoverTools :: Options -> IO (Either SynapseCCError ToolLocations)
discoverTools opts = do
  let debug = optDebug opts

  synapsePath <- case optSynapsePath opts of
    Just explicit -> resolveExplicit "synapse" explicit debug
    Nothing       -> findTool debug "synapse" synapseFallbackPaths

  case synapsePath of
    Nothing -> pure $ Left $ ToolNotFound "synapse" synapseSuggestions
    Just synapseToolPath -> do
      hubCodegenPath <- case optHubCodegenPath opts of
        Just explicit -> resolveExplicit "hub-codegen" explicit debug
        Nothing       -> findTool debug "hub-codegen" hubCodegenFallbackPaths

      case hubCodegenPath of
        Nothing -> pure $ Left $ ToolNotFound "hub-codegen" hubCodegenSuggestions
        Just hubCodegenToolPath -> do
          -- Run --version for each discovered tool
          synapseVer    <- getToolVersion (toolPathToFilePath synapseToolPath)
          hubCodegenVer <- getToolVersion (toolPathToFilePath hubCodegenToolPath)

          logInfo $ "  synapse     " <> T.pack (toolPathToFilePath synapseToolPath) <> "  (" <> synapseVer <> ")"
          logInfo $ "  hub-codegen " <> T.pack (toolPathToFilePath hubCodegenToolPath) <> "  (" <> hubCodegenVer <> ")"

          pure $ Right $ ToolLocations
            { toolSynapse           = synapseToolPath
            , toolHubCodegen        = hubCodegenToolPath
            , toolSynapseVersion    = synapseVer
            , toolHubCodegenVersion = hubCodegenVer
            }

-- | Resolve an explicitly-provided path, failing clearly if it doesn't exist
resolveExplicit :: String -> FilePath -> Bool -> IO (Maybe ToolPath)
resolveExplicit name path debug = do
  exists <- doesFileExist path
  if exists
    then pure $ Just $ classifyPath path
    else do
      logDebug debug $ "  [!] " <> T.pack name <> ": explicit path not found: " <> T.pack path
      pure Nothing

-- | Find a tool: check PATH first, then fallback paths
findTool :: Bool -> String -> IO [FilePath] -> IO (Maybe ToolPath)
findTool debug name fallbacksIO = do
  -- Check PATH first (i.e. `which <name>`)
  mbWhich <- findExecutable name
  case mbWhich of
    Just path -> do
      logDebug debug $ "  " <> T.pack name <> ": found via PATH at " <> T.pack path
      pure $ Just $ SystemPath path
    Nothing -> do
      logDebug debug $ "  " <> T.pack name <> ": not in PATH, searching fallback locations..."
      paths <- fallbacksIO
      tryPaths paths
  where
    tryPaths [] = pure Nothing
    tryPaths (path:rest) = do
      exists <- doesFileExist path
      if exists
        then do
          logDebug debug $ "    Found: " <> T.pack path
          pure $ Just $ classifyPath path
        else tryPaths rest

-- | Classify a path based on where it was found
classifyPath :: FilePath -> ToolPath
classifyPath path
  | "dist-newstyle" `elem` splitPath path = LocalDev path
  | "target"        `elem` splitPath path = LocalDev path
  | ".plexus/bin"   `elem` splitPath path = PlexusBin path
  | otherwise                             = SystemPath path
  where
    splitPath = filter (not . null) . wordsBy (== '/')
    wordsBy p s = case dropWhile p s of
      [] -> []
      s' -> let (w, s'') = break p s' in w : wordsBy p s''

-- | Convert ToolPath to FilePath
toolPathToFilePath :: ToolPath -> FilePath
toolPathToFilePath = \case
  LocalDev path   -> path
  SystemPath path -> path
  PlexusBin path  -> path

-- | Run a tool with @--version@ and return the version string.
-- Strips a leading "v" and takes only the first line.
-- Returns @"unknown"@ if the call fails for any reason.
getToolVersion :: FilePath -> IO Text
getToolVersion exe = do
  result <- try (readProcessWithExitCode exe ["--version"] "") :: IO (Either SomeException (ExitCode, String, String))
  case result of
    Left _             -> pure "unknown"
    Right (_, out, _) ->
      let firstLine = T.strip $ T.pack $ head (lines out ++ [""])
          -- Take last word (handles "hub-codegen 0.1.0" and "3.5.0")
          lastWord  = case reverse (T.words firstLine) of
                        (w:_) -> w
                        []    -> ""
          ver = case T.unpack lastWord of
                  ('v':rest) -> T.pack rest
                  _          -> lastWord
      in pure $ if T.null ver then "unknown" else ver

-- ============================================================================
-- dist-newstyle Glob Search
-- ============================================================================

-- | Search dist-newstyle for a built executable, returning the most recently
-- modified match (newest build wins).
--
-- Walks the pattern:
--   <root>/dist-newstyle/build/*\/ghc-*\/<pkg>-*\/x\/<exe>\/build\/<exe>\/<exe>
findInDistNewstyle :: FilePath  -- ^ project root (e.g. "../synapse")
                   -> String    -- ^ executable name (e.g. "synapse")
                   -> IO (Maybe FilePath)
findInDistNewstyle root exe = do
  let buildDir = root </> "dist-newstyle" </> "build"
  exists <- doesDirectoryExist buildDir
  if not exists
    then pure Nothing
    else do
      -- Level 1: arch dirs (e.g. aarch64-linux, x86_64-darwin)
      archDirs <- safeListDirectory buildDir
      candidates <- fmap concat $ forM archDirs $ \arch -> do
        let archPath = buildDir </> arch
        isDir <- doesDirectoryExist archPath
        if not isDir then pure [] else do

          -- Level 2: ghc-* dirs
          ghcDirs <- safeListDirectory archPath
          fmap concat $ forM ghcDirs $ \ghcDir -> do
            if not ("ghc-" `isPrefixOfStr` ghcDir) then pure [] else do
              let ghcPath = archPath </> ghcDir

              -- Level 3: <pkg>-* dirs
              pkgDirs <- safeListDirectory ghcPath
              fmap concat $ forM pkgDirs $ \pkgDir -> do
                let pkgPath = ghcPath </> pkgDir
                isDir2 <- doesDirectoryExist pkgPath
                if not isDir2 then pure [] else do

                  -- Level 4: x/<exe>/build/<exe>/<exe>
                  let candidate = pkgPath </> "x" </> exe </> "build" </> exe </> exe
                  exists2 <- doesFileExist candidate
                  if exists2 then pure [candidate] else pure []

      case candidates of
        []  -> pure Nothing
        [c] -> pure $ Just c
        cs  -> do
          -- Pick the most recently modified binary
          withTimes <- forM cs $ \c -> do
            t <- getModificationTime c
            pure (t, c)
          pure $ Just $ snd $ maximumBy (comparing fst) withTimes
  where
    isPrefixOfStr prefix str = take (length prefix) str == prefix

    safeListDirectory dir =
      listDirectory dir `catch` \(_ :: SomeException) -> pure []

-- ============================================================================
-- Fallback Search Paths (used only when not found in PATH)
-- ============================================================================

-- | Fallback paths for synapse (checked if not in PATH).
-- Uses glob-based dist-newstyle search to handle any arch/GHC version.
synapseFallbackPaths :: IO [FilePath]
synapseFallbackPaths = do
  home <- getHomeDirectory
  -- Search dist-newstyle trees relative to common project layouts
  mb1 <- findInDistNewstyle "../synapse" "synapse"
  mb2 <- findInDistNewstyle "../../synapse" "synapse"
  let devPaths = catMaybes [mb1, mb2]
  let installPaths =
        [ home </> ".plexus/bin/synapse"
        , home </> ".local/bin/synapse"
        , home </> ".cabal/bin/synapse"
        ]
  pure $ devPaths ++ installPaths

-- | Fallback paths for hub-codegen (checked if not in PATH)
hubCodegenFallbackPaths :: IO [FilePath]
hubCodegenFallbackPaths = do
  home <- getHomeDirectory
  let devPaths =
        [ "../hub-codegen/target/release/hub-codegen"
        , "../hub-codegen/target/debug/hub-codegen"
        , "../../hub-codegen/target/release/hub-codegen"
        , "../../hub-codegen/target/debug/hub-codegen"
        ]
      installPaths =
        [ home </> ".plexus/bin/hub-codegen"
        , home </> ".cargo/bin/hub-codegen"
        ]
  pure $ devPaths ++ installPaths

-- ============================================================================
-- Suggestions
-- ============================================================================

synapseSuggestions :: [Text]
synapseSuggestions =
  [ "Install synapse: cd ../synapse && cabal install exe:synapse"
  , "Or specify path: --synapse /path/to/synapse"
  , "Add to PATH: export PATH=\"$HOME/.local/bin:$PATH\""
  ]

hubCodegenSuggestions :: [Text]
hubCodegenSuggestions =
  [ "Install hub-codegen: cd ../hub-codegen && cargo install --path ."
  , "Or specify path: --hub-codegen /path/to/hub-codegen"
  , "Add to PATH: export PATH=\"$HOME/.cargo/bin:$PATH\""
  ]
