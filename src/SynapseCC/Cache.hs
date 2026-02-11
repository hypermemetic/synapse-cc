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
  ) where

import Control.Exception (catch, SomeException)
import Control.Monad (when)
import Data.Aeson (decode, encode, eitherDecodeFileStrict)
import qualified Data.ByteString.Lazy as BL
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeDirectoryRecursive, getHomeDirectory)
import System.FilePath ((</>))

import SynapseCC.Types

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
                      -- TODO: Check schema hashes and IR hashes for granular invalidation
                      -- For now, return full cache hit if versions match
                      when debug $ putStrLn "[+] Full cache hit (versions match)"
                      pure FullCacheHit

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
