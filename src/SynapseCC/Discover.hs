-- | Tool discovery - finding synapse and hub-codegen executables
module SynapseCC.Discover
  ( discoverTools
  , findTool
  , toolPathToFilePath
  ) where

import Control.Monad (when)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist, findExecutable, getHomeDirectory)
import System.FilePath ((</>))

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
      logInfo $ "  synapse     " <> T.pack (toolPathToFilePath synapseToolPath)

      hubCodegenPath <- case optHubCodegenPath opts of
        Just explicit -> resolveExplicit "hub-codegen" explicit debug
        Nothing       -> findTool debug "hub-codegen" hubCodegenFallbackPaths

      case hubCodegenPath of
        Nothing -> pure $ Left $ ToolNotFound "hub-codegen" hubCodegenSuggestions
        Just hubCodegenToolPath -> do
          logInfo $ "  hub-codegen " <> T.pack (toolPathToFilePath hubCodegenToolPath)

          pure $ Right $ ToolLocations
            { toolSynapse    = synapseToolPath
            , toolHubCodegen = hubCodegenToolPath
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
findTool :: Bool -> String -> (FilePath -> [FilePath]) -> IO (Maybe ToolPath)
findTool debug name fallbacksF = do
  -- Check PATH first (i.e. `which <name>`)
  mbWhich <- findExecutable name
  case mbWhich of
    Just path -> do
      logDebug debug $ "  " <> T.pack name <> ": found via PATH at " <> T.pack path
      pure $ Just $ SystemPath path
    Nothing -> do
      logDebug debug $ "  " <> T.pack name <> ": not in PATH, searching fallback locations..."
      home <- getHomeDirectory
      tryPaths (fallbacksF home)
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

-- ============================================================================
-- Fallback Search Paths (used only when not found in PATH)
-- ============================================================================

-- | Fallback paths for synapse (checked if not in PATH)
synapseFallbackPaths :: FilePath -> [FilePath]
synapseFallbackPaths home =
  [ -- Local development builds
    "../synapse/dist-newstyle/build/aarch64-linux/ghc-9.4.8/plexus-synapse-0.2.0.0/x/synapse/build/synapse/synapse"
  , "../synapse/dist-newstyle/build/x86_64-linux/ghc-9.4.8/plexus-synapse-0.2.0.0/x/synapse/build/synapse/synapse"
  , "../../synapse/dist-newstyle/build/aarch64-linux/ghc-9.4.8/plexus-synapse-0.2.0.0/x/synapse/build/synapse/synapse"
  , "../../synapse/dist-newstyle/build/x86_64-linux/ghc-9.4.8/plexus-synapse-0.2.0.0/x/synapse/build/synapse/synapse"
    -- Install locations
  , home </> ".plexus/bin/synapse"
  , home </> ".local/bin/synapse"
  , home </> ".cabal/bin/synapse"
  ]

-- | Fallback paths for hub-codegen (checked if not in PATH)
hubCodegenFallbackPaths :: FilePath -> [FilePath]
hubCodegenFallbackPaths home =
  [ -- Local development builds
    "../hub-codegen/target/release/hub-codegen"
  , "../hub-codegen/target/debug/hub-codegen"
  , "../../hub-codegen/target/release/hub-codegen"
  , "../../hub-codegen/target/debug/hub-codegen"
    -- Install locations
  , home </> ".plexus/bin/hub-codegen"
  , home </> ".cargo/bin/hub-codegen"
  ]

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
