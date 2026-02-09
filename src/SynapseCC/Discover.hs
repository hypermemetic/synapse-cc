-- | Tool discovery - finding synapse and hub-codegen executables
module SynapseCC.Discover
  ( discoverTools
  , findTool
  , toolPathToFilePath
  ) where

import Control.Monad (filterM)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist, findExecutable, getHomeDirectory)
import System.FilePath ((</>))

import SynapseCC.Types

-- ============================================================================
-- Tool Discovery
-- ============================================================================

-- | Discover all required tools
discoverTools :: Bool -> IO (Either SynapseCCError ToolLocations)
discoverTools debug = do
  when debug $ putStrLn "[*] Discovering tools..."

  synapsePath <- findTool debug "synapse" synapsePaths
  case synapsePath of
    Nothing -> pure $ Left $ ToolNotFound "synapse" synapseSuggestions
    Just synapseToolPath -> do
      when debug $ putStrLn $ "  [+] Found synapse at " ++ toolPathToFilePath synapseToolPath

      hubCodegenPath <- findTool debug "hub-codegen" hubCodegenPaths
      case hubCodegenPath of
        Nothing -> pure $ Left $ ToolNotFound "hub-codegen" hubCodegenSuggestions
        Just hubCodegenToolPath -> do
          when debug $ putStrLn $ "  [+] Found hub-codegen at " ++ toolPathToFilePath hubCodegenToolPath

          pure $ Right $ ToolLocations
            { toolSynapse = synapseToolPath
            , toolHubCodegen = hubCodegenToolPath
            }

-- | Find a tool by checking multiple locations
findTool :: Bool -> String -> (FilePath -> [FilePath]) -> IO (Maybe ToolPath)
findTool debug name pathsF = do
  home <- getHomeDirectory
  let paths = pathsF home

  when debug $ putStrLn $ "  Searching for " ++ name ++ "..."

  -- Try to find the tool in priority order
  tryPaths paths
  where
    tryPaths [] = do
      -- Last resort: check system PATH
      mbSystemPath <- findExecutable name
      case mbSystemPath of
        Just path -> do
          when debug $ putStrLn $ "    Found in PATH: " ++ path
          pure $ Just $ SystemPath path
        Nothing -> pure Nothing

    tryPaths (path:rest) = do
      exists <- doesFileExist path
      if exists
        then do
          when debug $ putStrLn $ "    Found: " ++ path
          pure $ Just $ classifyPath path
        else tryPaths rest

-- | Classify a path based on where it was found
classifyPath :: FilePath -> ToolPath
classifyPath path
  | "dist-newstyle" `elem` splitPath path = LocalDev path
  | "target" `elem` splitPath path = LocalDev path
  | ".plexus/bin" `elem` splitPath path = PlexusBin path
  | otherwise = SystemPath path
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
-- Search Paths
-- ============================================================================

-- | Search paths for synapse (in priority order)
synapsePaths :: FilePath -> [FilePath]
synapsePaths home =
  [ -- Local development builds
    "../synapse/dist-newstyle/build/aarch64-linux/ghc-9.4.8/plexus-synapse-0.2.0.0/x/synapse/build/synapse/synapse"
  , "../synapse/dist-newstyle/build/x86_64-linux/ghc-9.4.8/plexus-synapse-0.2.0.0/x/synapse/build/synapse/synapse"
  , "../../synapse/dist-newstyle/build/aarch64-linux/ghc-9.4.8/plexus-synapse-0.2.0.0/x/synapse/build/synapse/synapse"
  , "../../synapse/dist-newstyle/build/x86_64-linux/ghc-9.4.8/plexus-synapse-0.2.0.0/x/synapse/build/synapse/synapse"
    -- Plexus bin directory
  , home </> ".plexus/bin/synapse"
    -- Cabal install location
  , home </> ".cabal/bin/synapse"
  ]

-- | Search paths for hub-codegen (in priority order)
hubCodegenPaths :: FilePath -> [FilePath]
hubCodegenPaths home =
  [ -- Local development builds
    "../hub-codegen/target/release/hub-codegen"
  , "../hub-codegen/target/debug/hub-codegen"
  , "../../hub-codegen/target/release/hub-codegen"
  , "../../hub-codegen/target/debug/hub-codegen"
    -- Plexus bin directory
  , home </> ".plexus/bin/hub-codegen"
    -- Cargo install location
  , home </> ".cargo/bin/hub-codegen"
  ]

-- ============================================================================
-- Suggestions
-- ============================================================================

-- | Suggestions for installing synapse
synapseSuggestions :: [Text]
synapseSuggestions =
  [ "Build synapse: cd ../synapse && cabal build"
  , "Install synapse: cabal install synapse"
  , "Add to PATH: export PATH=\"$PATH:~/.plexus/bin\""
  ]

-- | Suggestions for installing hub-codegen
hubCodegenSuggestions :: [Text]
hubCodegenSuggestions =
  [ "Build hub-codegen: cd ../hub-codegen && cargo build --release"
  , "Install hub-codegen: cargo install --path ../hub-codegen"
  , "Add to PATH: export PATH=\"$PATH:~/.plexus/bin\""
  ]

-- ============================================================================
-- Helpers
-- ============================================================================

when :: Applicative f => Bool -> f () -> f ()
when True action = action
when False _ = pure ()
