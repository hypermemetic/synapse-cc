{-# LANGUAGE OverloadedStrings #-}

-- | Caching support with version-aware invalidation
module SynapseCC.Cache
  ( -- * Cache operations
    validateCache
  , readIRCacheManifest
  , readCodeCacheManifest
  , writeIRCacheManifest
  , writeCodeCacheManifest
  , getCacheDir
  , clearCache

    -- * V2 Validation (internal, exposed for testing)
  , validatePluginCaches
  , validatePluginCache
  ) where

import Control.Exception (catch, SomeException)
import Control.Monad (when, forM_)
import Data.Aeson (encode, eitherDecodeFileStrict)
import qualified Data.ByteString.Lazy as BL
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeDirectoryRecursive, getHomeDirectory)
import System.FilePath ((</>))

import SynapseCC.Types
import qualified SynapseCC.Dependency as Dep

-- ============================================================================
-- Cache Directory Structure
-- ============================================================================

-- Cache directory structure:
-- ~/.cache/plexus-codegen/
-- ├── synapse/
-- │   ├── schemas/          # Level 1: Schema cache (future)
-- │   └── ir/               # Level 2: IR cache
-- │       ├── manifest.json # IR cache manifest
-- │       ├── cone.json     # Generated IR fragments
-- │       └── arbor.json
-- └── hub-codegen/
--     └── typescript/       # Level 3: Code cache
--         ├── manifest.json # Code cache manifest
--         ├── cone/         # Generated code per plugin
--         └── arbor/

-- | Get the cache base directory, expanding ~ to home directory
getCacheDir :: Options -> IO FilePath
getCacheDir opts = expandTilde (optCacheDir opts)

-- | Expand ~ to home directory if path starts with ~
expandTilde :: FilePath -> IO FilePath
expandTilde path
  | "~/" `isPrefixOf` path = do
      home <- getHomeDirectory
      pure $ home ++ drop 1 path  -- Replace ~ with home, keeping the /
  | path == "~" = getHomeDirectory
  | otherwise = pure path

-- | Get IR cache directory
getIRCacheDir :: Options -> Backend -> IO FilePath
getIRCacheDir opts backend = do
  baseDir <- getCacheDir opts
  pure $ baseDir </> "synapse" </> "ir" </> T.unpack (backendName backend)

-- | Get code cache directory
getCodeCacheDir :: Options -> Backend -> Target -> IO FilePath
getCodeCacheDir opts backend target = do
  baseDir <- getCacheDir opts
  pure $ baseDir </> "hub-codegen" </> targetName target </> T.unpack (backendName backend)
  where
    targetName TypeScript = "typescript"
    targetName Python = "python"
    targetName Rust = "rust"

-- ============================================================================
-- Cache Reading
-- ============================================================================

-- | Read IR cache manifest
readIRCacheManifest :: Options -> Backend -> IO (Either SynapseCCError IRCacheManifest)
readIRCacheManifest opts backend = do
  cacheDir <- getIRCacheDir opts backend
  let manifestPath = cacheDir </> "manifest.json"
  exists <- doesFileExist manifestPath
  if not exists
    then pure $ Left $ CacheError "IR cache manifest not found"
    else do
      result <- eitherDecodeFileStrict manifestPath
      case result of
        Left err -> pure $ Left $ CacheError $ "Failed to parse IR cache manifest: " <> T.pack err
        Right manifest -> pure $ Right manifest

-- | Read code cache manifest
readCodeCacheManifest :: Options -> Backend -> Target -> IO (Either SynapseCCError CodeCacheManifest)
readCodeCacheManifest opts backend target = do
  cacheDir <- getCodeCacheDir opts backend target
  let manifestPath = cacheDir </> "manifest.json"
  exists <- doesFileExist manifestPath
  if not exists
    then pure $ Left $ CacheError "Code cache manifest not found"
    else do
      result <- eitherDecodeFileStrict manifestPath
      case result of
        Left err -> pure $ Left $ CacheError $ "Failed to parse code cache manifest: " <> T.pack err
        Right manifest -> pure $ Right manifest

-- ============================================================================
-- Cache Validation
-- ============================================================================

-- | Validate cache with version-aware checking
-- Returns CacheResult indicating what needs regeneration
validateCache :: Config -> IO CacheResult
validateCache config = do
  let opts = cfgOptions config
      backend = cfgBackend config
      target = cfgTarget config
      debug = optDebug opts

  -- If --force flag is set, skip cache entirely
  if optForce opts
    then do
      when debug $ putStrLn "[!] --force flag set, skipping cache"
      pure $ CacheMiss ManifestNotFound
    else do
      -- Try to read IR cache manifest
      irManifestResult <- readIRCacheManifest opts backend
      case irManifestResult of
        Left err -> do
          when debug $ putStrLn $ "[!] IR cache miss: " ++ T.unpack (formatError err)
          pure $ CacheMiss ManifestNotFound

        Right irManifest -> do
          -- Check tool versions against IR cache
          let irToolchain = ircmToolchain irManifest
          if tvSynapseCC irToolchain /= synapseCCVersion ||
             tvSynapse irToolchain /= "0.2.0.0"  -- TODO: Get from synapse somehow
            then do
              when debug $ putStrLn "[!] Tool versions changed, invalidating IR cache"
              pure $ CacheMiss ToolVersionChanged
            else do
              -- IR cache valid, check code cache
              codeManifestResult <- readCodeCacheManifest opts backend target
              case codeManifestResult of
                Left err -> do
                  when debug $ putStrLn $ "[!] Code cache miss: " ++ T.unpack (formatError err)
                  -- IR is cached, but code is not
                  pure $ CacheMiss ManifestNotFound

                Right codeManifest -> do
                  -- Check tool versions against code cache
                  let codeToolchain = ccmToolchain codeManifest
                  if tvSynapseCC codeToolchain /= synapseCCVersion ||
                     tvSynapse codeToolchain /= "0.2.0.0" ||  -- TODO: Get from synapse
                     isJust (tvHubCodegen codeToolchain) && tvHubCodegen codeToolchain /= Just "0.1.0"  -- TODO: Get from hub-codegen
                    then do
                      when debug $ putStrLn "[!] Tool versions changed, invalidating code cache"
                      pure $ CacheMiss ToolVersionChanged
                    else do
                      -- V2: Check plugin hashes for granular invalidation
                      when debug $ putStrLn "[*] Checking plugin hashes for granular invalidation..."
                      validatePluginCaches irManifest codeManifest debug

-- ============================================================================
-- V2 Granular Cache Validation
-- ============================================================================

-- | Validate plugin caches with V2 granular hash checking
validatePluginCaches :: IRCacheManifest -> CodeCacheManifest -> Bool -> IO CacheResult
validatePluginCaches irManifest codeManifest debug = do
  let irPlugins = ircmPlugins irManifest
      codePlugins = ccmPlugins codeManifest
      allPluginNames = Set.toList $ Set.union (Map.keysSet irPlugins) (Map.keysSet codePlugins)

  -- Check each plugin for direct invalidation (schema/IR hash changes)
  results <- mapM (validatePluginCache irManifest codeManifest debug) allPluginNames

  -- Collect directly invalid plugins
  let directlyInvalidPlugins = Set.fromList [name | (name, False) <- results]
      directlyValidPlugins = [name | (name, True) <- results]

  -- Build dependency graph from IR cache
  let depGraph = Map.map ipcDependencies irPlugins

  -- Find transitively invalid plugins using dependency resolution
  let allInvalidPlugins = Dep.findInvalidPlugins directlyInvalidPlugins depGraph
      invalidPluginsList = Set.toList allInvalidPlugins
      validPluginsList = filter (`Set.notMember` allInvalidPlugins) directlyValidPlugins

  -- Report transitive invalidation
  when debug $ do
    let transitivelyInvalid = Set.difference allInvalidPlugins directlyInvalidPlugins
    when (not $ Set.null transitivelyInvalid) $ do
      putStrLn "[!] Transitive invalidation due to dependencies:"
      forM_ (Set.toList transitivelyInvalid) $ \name ->
        putStrLn $ "    - " ++ T.unpack name ++ " (depends on invalid plugin)"

  if null invalidPluginsList
    then do
      when debug $ putStrLn $ "[+] Full cache hit - all " ++ show (length validPluginsList) ++ " plugins valid"
      pure FullCacheHit
    else do
      when debug $ do
        putStrLn $ "[!] Partial cache hit:"
        putStrLn $ "    Valid: " ++ show (length validPluginsList) ++ " plugins"
        putStrLn $ "    Invalid: " ++ show (length invalidPluginsList) ++ " plugins (including transitive)"
        forM_ invalidPluginsList $ \name ->
          putStrLn $ "      - " ++ T.unpack name
      pure $ PartialCacheHit validPluginsList invalidPluginsList

-- | Validate a single plugin's cache
-- Returns (plugin name, is valid)
validatePluginCache :: IRCacheManifest -> CodeCacheManifest -> Bool -> Text -> IO (Text, Bool)
validatePluginCache irManifest codeManifest debug pluginName = do
  let irPlugins = ircmPlugins irManifest
      codePlugins = ccmPlugins codeManifest

  case (Map.lookup pluginName irPlugins, Map.lookup pluginName codePlugins) of
    (Nothing, Nothing) -> do
      -- Plugin not in either cache - invalid
      when debug $ putStrLn $ "[!] Plugin '" ++ T.unpack pluginName ++ "' not found in cache"
      pure (pluginName, False)

    (Just _irCache, Nothing) -> do
      -- IR cached but code not generated - invalid
      when debug $ putStrLn $ "[!] Plugin '" ++ T.unpack pluginName ++ "' has IR cache but no code cache"
      pure (pluginName, False)

    (Nothing, Just _codeCache) -> do
      -- Code exists but no IR cache - invalid (shouldn't happen)
      when debug $ putStrLn $ "[!] Plugin '" ++ T.unpack pluginName ++ "' has code cache but no IR cache"
      pure (pluginName, False)

    (Just irCache, Just codeCache) -> do
      -- Both caches exist - perform V2 granular validation
      validatePluginV2 irCache codeCache pluginName debug

-- | V2 validation logic using self_hash and children_hash
validatePluginV2 :: IRPluginCache -> CodePluginCache -> Text -> Bool -> IO (Text, Bool)
validatePluginV2 irCache codeCache pluginName debug = do
  -- Check if IR hash in code cache matches IR hash in IR cache
  let cachedIRHash = ipcIRHash irCache
      codeIRHash = cpcIRHash codeCache
      cachedSelfHash = ipcSelfHash irCache
      cachedChildrenHash = ipcChildrenHash irCache

  if T.null cachedIRHash || T.null codeIRHash
    then do
      -- Missing hash data - consider invalid for safety
      reportInvalidation pluginName "Missing hash data" debug
      pure (pluginName, False)
    else if cachedIRHash == codeIRHash
      then do
        -- IR hash matches - cache is valid
        reportCacheHit pluginName cachedSelfHash cachedChildrenHash debug
        pure (pluginName, True)
      else do
        -- IR hash changed - analyze granularity with V2 hashes
        analyzeHashChange pluginName irCache codeIRHash debug
        pure (pluginName, False)

-- | Report cache hit with V2 hash details
reportCacheHit :: Text -> Text -> Text -> Bool -> IO ()
reportCacheHit pluginName selfHash childrenHash debug = do
  when debug $ do
    putStrLn $ "[+] Cache hit: '" ++ T.unpack pluginName ++ "'"
    when (not $ T.null selfHash) $
      putStrLn $ "    self_hash:     " ++ T.unpack (T.take 8 selfHash) ++ "..."
    when (not $ T.null childrenHash) $
      putStrLn $ "    children_hash: " ++ T.unpack (T.take 8 childrenHash) ++ "..."

-- | Report cache invalidation with detailed reason
reportInvalidation :: Text -> String -> Bool -> IO ()
reportInvalidation pluginName reason debug = do
  when debug $ do
    putStrLn $ "[!] Cache miss: '" ++ T.unpack pluginName ++ "'"
    putStrLn $ "    Reason: " ++ reason

-- | Analyze what changed using V2 granular hashes
analyzeHashChange :: Text -> IRPluginCache -> Text -> Bool -> IO ()
analyzeHashChange pluginName irCache newCodeHash debug = do
  let cachedIRHash = ipcIRHash irCache
      cachedSelfHash = ipcSelfHash irCache
      cachedChildrenHash = ipcChildrenHash irCache

  when debug $ do
    putStrLn $ "[!] Cache miss: '" ++ T.unpack pluginName ++ "'"
    putStrLn $ "    IR hash changed:"
    putStrLn $ "      cached: " ++ T.unpack (T.take 8 cachedIRHash) ++ "..."
    putStrLn $ "      new:    " ++ T.unpack (T.take 8 newCodeHash) ++ "..."

    -- V2 granular analysis (when fresh hashes are available)
    if T.null cachedSelfHash && T.null cachedChildrenHash
      then do
        putStrLn "    V2 hashes unavailable - using V1 validation"
        putStrLn "    Reason: Schema or IR changed (full regeneration needed)"
      else do
        putStrLn "    V2 granular analysis:"
        when (not $ T.null cachedSelfHash) $
          putStrLn $ "      self_hash:     " ++ T.unpack (T.take 8 cachedSelfHash) ++ "... (methods)"
        when (not $ T.null cachedChildrenHash) $
          putStrLn $ "      children_hash: " ++ T.unpack (T.take 8 cachedChildrenHash) ++ "... (dependencies)"
        putStrLn "    Note: Fresh schema comparison needed for granular invalidation"
        putStrLn "          (requires fetching current schema from backend)"

-- ============================================================================
-- Cache Writing
-- ============================================================================

-- | Write IR cache manifest
writeIRCacheManifest :: Options -> Backend -> Map Text IRPluginCache -> IO ()
writeIRCacheManifest opts backend plugins = do
  cacheDir <- getIRCacheDir opts backend
  createDirectoryIfMissing True cacheDir

  currentTime <- getCurrentTime
  let timestamp = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" currentTime

  let manifest = IRCacheManifest
        { ircmVersion = "1.0"
        , ircmIRVersion = "2.0"
        , ircmToolchain = ToolchainVersions
            { tvSynapseCC = synapseCCVersion
            , tvSynapse = "0.2.0.0"  -- TODO: Get from synapse
            , tvHubCodegen = Nothing
            }
        , ircmUpdatedAt = timestamp
        , ircmPlugins = plugins
        }

  let manifestPath = cacheDir </> "manifest.json"
  BL.writeFile manifestPath (encode manifest)

-- | Write code cache manifest
writeCodeCacheManifest :: Options -> Backend -> Target -> Map Text CodePluginCache -> IO ()
writeCodeCacheManifest opts backend target plugins = do
  cacheDir <- getCodeCacheDir opts backend target
  createDirectoryIfMissing True cacheDir

  currentTime <- getCurrentTime
  let timestamp = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" currentTime

  let manifest = CodeCacheManifest
        { ccmVersion = "1.0"
        , ccmTarget = T.pack $ case target of
            TypeScript -> "typescript"
            Python -> "python"
            Rust -> "rust"
        , ccmToolchain = ToolchainVersions
            { tvSynapseCC = synapseCCVersion
            , tvSynapse = "0.2.0.0"  -- TODO: Get from synapse
            , tvHubCodegen = Just "0.1.0"  -- TODO: Get from hub-codegen
            }
        , ccmUpdatedAt = timestamp
        , ccmPlugins = plugins
        }

  let manifestPath = cacheDir </> "manifest.json"
  BL.writeFile manifestPath (encode manifest)

-- ============================================================================
-- Cache Management
-- ============================================================================

-- | Clear the entire cache directory
clearCache :: Options -> IO ()
clearCache opts = do
  cacheDir <- getCacheDir opts
  exists <- doesFileExist cacheDir
  when exists $ do
    catch
      (removeDirectoryRecursive cacheDir)
      (\(e :: SomeException) -> putStrLn $ "Warning: Failed to clear cache: " ++ show e)
