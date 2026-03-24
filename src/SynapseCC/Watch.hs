{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Watch mode: poll backend for changes, incrementally rebuild affected plugins
module SynapseCC.Watch
  ( -- * Entry point
    runWatch

    -- * Pure utilities (exported for testing)
  , matchesAnyPrefix
  , parseUrl
  , extractPluginHashesFromBytes
  , filterTargets
  , buildConfigFromTarget

    -- * IO utilities (exported for testing)
  , fetchBackendHash
  , makeSubstrateConfig
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (try, SomeException)
import Control.Monad (forM_, when, unless)
import Data.Aeson (Value)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AKey
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

import Plexus.Client (SubstrateConfig(..), defaultConfig)
import qualified Plexus.Transport as Transport
import Plexus.Types (PlexusStreamItem(..))
import Synapse.Monad (initEnv, runSynapseM)
import Synapse.IR.Builder (buildIR)
import qualified Synapse.Log as Log
import qualified Katip

import SynapseCC.Cache (expandTilde)
import qualified SynapseCC.Config as Config
import SynapseCC.Config (loadSynapseConfig)
import SynapseCC.Logging
import SynapseCC.Merge (applyMerge)
import SynapseCC.Pipeline (formatSynapseError, generateCode, runPipeline)
import SynapseCC.Types

-- ============================================================================
-- Public Entry Point
-- ============================================================================

-- | Run the watch loop.
-- 1. Load synapse.config.json (falls back to defaults from CLI args)
-- 2. Full initial build across all active targets
-- 3. Poll {backend}.hash every pollInterval ms:
--    - unchanged → no-op
--    - changed   → fetch IR, diff plugin hashes, partial-rebuild changed plugins
runWatch :: WatchArgs -> ToolLocations -> IO ()
runWatch watchArgs tools = do
  let debug  = optDebug (waOptions watchArgs)
      bkName = waBackend watchArgs

  -- Load synapse.config.json
  cfgResult <- loadSynapseConfig
  synapseConfig <- case cfgResult of
    Left err -> do
      logInfo $ "[!] Config: " <> err
      logInfo   "    Falling back to CLI defaults"
      pure (synapseConfigFromArgs watchArgs)
    Right cfg -> pure cfg

  let allTargets    = scTargets synapseConfig
      activeTargets = filterTargets watchArgs allTargets

  when (Map.null activeTargets) $
    logInfo "[!] No targets with \"plugins\" in their generate list — nothing to watch"

  -- Full initial build for each active target
  logStep "Running initial build..."
  forM_ (Map.toList activeTargets) $ \(targetName, targetCfg) -> do
    let config = buildConfigFromTarget watchArgs synapseConfig targetCfg
    result <- runPipeline config tools
    case result of
      Left err -> let msg  = T.strip (formatError err)
                      bare = maybe msg T.stripStart (T.stripPrefix "[!] Error:" msg)
                  in logError $ targetName <> ": " <> bare
      Right _  -> logSuccess $ targetName <> " built"

  -- State: last seen backend hash
  lastHashRef <- newIORef (Nothing :: Maybe Text)

  -- Config hot-reload state
  let hotReload = wcHotReload (scWatch synapseConfig)
      pollMs    = maybe (wcPollInterval (scWatch synapseConfig)) id (waInterval watchArgs)
      pollUs    = pollMs * 1000
  configRef <- newIORef synapseConfig

  when hotReload $
    logInfo "  Config hot-reload enabled (watching synapse.config.json)"

  logInfo $ "Watching " <> bkName <> " (polling every " <> T.pack (show pollMs) <> "ms)..."

  let loop = do
        -- Hot-reload config if enabled
        when hotReload $ do
          newCfgResult <- loadSynapseConfig
          case newCfgResult of
            Right newCfg -> writeIORef configRef newCfg
            Left _       -> pure ()  -- keep old config on error

        currentCfg <- readIORef configRef
        let subCfg  = makeSubstrateConfig watchArgs currentCfg

        hashResult <- (try (fetchBackendHash subCfg bkName) :: IO (Either SomeException (Either Text Text)))

        case hashResult of
          Left ex -> logInfo $ "[!] Backend unreachable: " <> T.pack (show ex)

          Right (Left err) -> logInfo $ "[!] Hash poll error: " <> err

          Right (Right newHash) -> do
            lastHash <- readIORef lastHashRef
            when (Just newHash /= lastHash) $ do
              -- Skip partial rebuild on first poll — initial build covered it
              when (isJust lastHash) $
                handleHashChange watchArgs currentCfg tools debug newHash

              writeIORef lastHashRef (Just newHash)

        threadDelay pollUs
        loop

  loop

-- ============================================================================
-- Hash Polling
-- ============================================================================

-- | Build a SubstrateConfig from watch args + synapse config URL
makeSubstrateConfig :: WatchArgs -> SynapseConfig -> SubstrateConfig
makeSubstrateConfig watchArgs synapseConfig =
  let (host, portTxt) = parseUrl (fromMaybe "ws://127.0.0.1:4444" (scUrl synapseConfig))
      port = read (T.unpack portTxt) :: Int
      bk   = waBackend watchArgs
  in (defaultConfig bk)
       { substrateHost = T.unpack host
       , substratePort = port
       }

-- | Call {backend}.hash and return the composite hash string.
fetchBackendHash :: SubstrateConfig -> Text -> IO (Either Text Text)
fetchBackendHash cfg bkName = do
  let method = bkName <> ".hash"
  result <- Transport.rpcCallWith cfg method Aeson.Null
  case result of
    Left err   -> pure $ Left $ T.pack (show err)
    Right items ->
      case mapMaybe extractHashValue items of
        (Right h : _) -> pure $ Right h
        (Left e  : _) -> pure $ Left e
        []             -> pure $ Left "No hash in response"

-- | Extract a hash string from a Plexus stream item for {backend}.hash calls.
-- Substrate sends content_type "{ns}.hash" with body {"event":"hash","value":"..."}.
extractHashValue :: PlexusStreamItem -> Maybe (Either Text Text)
extractHashValue (StreamData _ _ ct dat)
  | ".hash" `T.isSuffixOf` ct =
      case dat of
        Aeson.Object o ->
          case ( KM.lookup (AKey.fromText "event") o
               , KM.lookup (AKey.fromText "value") o ) of
            (Just (Aeson.String "hash"), Just (Aeson.String v)) -> Just (Right v)
            _ -> Nothing
        _ -> Nothing
  | otherwise = Nothing
extractHashValue (StreamError _ _ err _) = Just (Left err)
extractHashValue _                        = Nothing

-- ============================================================================
-- Change Handling
-- ============================================================================

-- | Handle a backend hash change: fetch full IR, diff plugin hashes, rebuild changed plugins.
handleHashChange
  :: WatchArgs
  -> SynapseConfig
  -> ToolLocations
  -> Bool    -- ^ debug
  -> Text    -- ^ new backend hash (informational)
  -> IO ()
handleHashChange watchArgs synapseConfig tools debug _newHash = do
  let bkName = waBackend watchArgs
      opts   = waOptions watchArgs
      (host, portTxt) = parseUrl (fromMaybe "ws://127.0.0.1:4444" (scUrl synapseConfig))
      port = read (T.unpack portTxt) :: Int
      pluginFilter = waPlugins watchArgs
      generatorInfo = ["synapse-cc:" <> synapseCCVersion]

  logInfo "Backend changed — fetching IR..."
  t0 <- getCurrentTime

  -- Fetch fresh IR via plexus-synapse library
  logger <- Log.makeLogger Katip.ErrorS
  env <- initEnv host port bkName logger
  irResult <- runSynapseM env (buildIR generatorInfo [])

  case irResult of
    Left synapseErr ->
      logInfo $ "[!] IR fetch failed: " <> formatSynapseError synapseErr

    Right ir -> do
      -- Write IR to cache path
      cacheDir <- expandTilde (optCacheDir opts)
      let irDir  = cacheDir </> "synapse" </> "ir" </> T.unpack bkName
          irFile = irDir </> "ir.json"
      createDirectoryIfMissing True irDir
      let irBytes = BL.toStrict (Aeson.encode ir)
      BS.writeFile irFile irBytes

      t1 <- getCurrentTime
      let fetchMs = round (diffUTCTime t1 t0 * 1000) :: Int

      -- Extract per-plugin hashes from fresh IR JSON
      let freshHashes = extractPluginHashesFromBytes irBytes

      -- Diff against cache to find changed/removed plugin namespaces
      (changedNs, removedNs) <- diffPluginHashes opts bkName freshHashes

      -- Apply prefix filter from CLI
      let filteredNs = if null pluginFilter
            then changedNs
            else filter (matchesAnyPrefix pluginFilter) changedNs

      let activeTargets = filterTargets watchArgs (scTargets synapseConfig)

      -- If plugins were removed from the backend, trigger a full rebuild per target.
      -- A partial rebuild cannot clean up stale files or fix index.ts exports.
      unless (null removedNs) $ do
        logInfo $ "  " <> T.pack (show (length removedNs))
               <> " plugin(s) removed — triggering full rebuild"
        when debug $ forM_ removedNs $ \ns ->
          logInfo $ "    - " <> ns
        forM_ (Map.toList activeTargets) $ \(targetName, targetCfg) -> do
          let config = buildConfigFromTarget watchArgs synapseConfig targetCfg
          result <- runPipeline config tools
          case result of
            Left err ->
              let msg  = T.strip (formatError err)
                  bare = maybe msg T.stripStart (T.stripPrefix "[!] Error:" msg)
              in logError $ targetName <> ": " <> bare
            Right _  -> logSuccess $ targetName <> " rebuilt (structural change)"

      if null filteredNs
        then when (null removedNs) $
               logInfo $ "  IR fetched in " <> T.pack (show fetchMs) <> "ms — no plugin changes"
        else do
          logInfo $ "  IR fetched in " <> T.pack (show fetchMs) <> "ms — "
                 <> T.pack (show (length filteredNs)) <> " plugin(s) changed"

          -- Rebuild each changed plugin across affected targets
          forM_ filteredNs $ \ns -> do
            forM_ (Map.toList activeTargets) $ \(targetName, targetCfg) ->
              when ("plugins" `elem` tcGenerate targetCfg || "all" `elem` tcGenerate targetCfg) $ do
                tStart <- getCurrentTime
                rebuildResult <- rebuildPlugin watchArgs synapseConfig tools (IRPath irFile) ns targetCfg debug
                tEnd <- getCurrentTime
                let ms = round (diffUTCTime tEnd tStart * 1000) :: Int
                case rebuildResult of
                  Left err -> logInfo $ "  [!] " <> ns <> " (" <> targetName <> "): " <> err
                  Right () -> logSuccess $ ns <> " (" <> targetName <> ") rebuilt in " <> T.pack (show ms) <> "ms"

-- | Rebuild a single plugin namespace for a single target using hub-codegen.
rebuildPlugin
  :: WatchArgs
  -> SynapseConfig
  -> ToolLocations
  -> IRPath
  -> Text         -- ^ plugin namespace
  -> TargetConfig
  -> Bool         -- ^ debug
  -> IO (Either Text ())
rebuildPlugin watchArgs synapseConfig tools irPath ns targetCfg _debug = do
  let config    = buildConfigFromTarget watchArgs synapseConfig targetCfg
      outputDir = tcOutputDir targetCfg

  codeResult <- generateCode config tools irPath (Just [ns])
  case codeResult of
    Left err -> pure $ Left $ formatError err
    Right out -> do
      let files      = coFiles out
          fileHashes = coFileHashes out
      _mergeResult <- applyMerge files fileHashes Map.empty outputDir
      pure $ Right ()

-- ============================================================================
-- Plugin Hash Helpers
-- ============================================================================

-- | Extract per-plugin composite hashes from raw IR JSON bytes.
-- Returns a Map of plugin namespace → composite hash.
extractPluginHashesFromBytes :: BS.ByteString -> Map Text Text
extractPluginHashesFromBytes bytes =
  case Aeson.decodeStrict bytes of
    Nothing -> Map.empty
    Just v  -> extractPluginHashesFromValue v

-- | Extract plugin hashes from a parsed IR JSON Value.
extractPluginHashesFromValue :: Value -> Map Text Text
extractPluginHashesFromValue v =
  case v of
    Aeson.Object obj ->
      case KM.lookup (AKey.fromText "irPluginHashes") obj of
        Just (Aeson.Object hashesObj) ->
          Map.fromList
            [ (AKey.toText k, extractCompositeHash hv)
            | (k, hv) <- KM.toList hashesObj
            ]
        _ -> Map.empty
    _ -> Map.empty

-- | Pull the "hash" field from a PluginHashInfo JSON object.
extractCompositeHash :: Value -> Text
extractCompositeHash (Aeson.Object o) =
  case KM.lookup (AKey.fromText "hash") o of
    Just (Aeson.String h) -> h
    _                     -> ""
extractCompositeHash _ = ""

-- | Compute which plugin namespaces have changed or been removed vs the cached IR manifest.
-- Returns (changed, removed).
-- If no cache exists, treats all current plugins as changed and none as removed.
diffPluginHashes :: Options -> Text -> Map Text Text -> IO ([Text], [Text])
diffPluginHashes opts bkName freshHashes = do
  cacheDir <- expandTilde (optCacheDir opts)
  let manifestPath = cacheDir </> "synapse" </> "ir" </> T.unpack bkName </> "manifest.json"
  exists <- doesFileExist manifestPath
  if not exists
    then pure (Map.keys freshHashes, [])
    else do
      result <- Aeson.eitherDecodeFileStrict manifestPath :: IO (Either String IRCacheManifest)
      case result of
        Left _         -> pure (Map.keys freshHashes, [])
        Right manifest -> do
          let changed = Map.keys $ Map.filterWithKey (isChanged manifest) freshHashes
              removed = Map.keys $ Map.difference (ircmPlugins manifest) freshHashes
          pure (changed, removed)
  where
    isChanged manifest ns newHash =
      case Map.lookup ns (ircmPlugins manifest) of
        Nothing     -> True  -- plugin is new
        Just cached -> ipcSchemaHash cached /= newHash

-- ============================================================================
-- Utilities
-- ============================================================================

-- | Does a plugin namespace match any of the given prefix filters?
-- A prefix "echo" matches "echo", "echo.health", "echo.workspace.repos", etc.
matchesAnyPrefix :: [Text] -> Text -> Bool
matchesAnyPrefix prefixes ns =
  any (\p -> p == ns || (p <> ".") `T.isPrefixOf` ns) prefixes

-- | Build a Config from WatchArgs and a TargetConfig entry.
-- Thin wrapper around 'Config.buildConfigFromTarget' extracting Options from WatchArgs.
buildConfigFromTarget :: WatchArgs -> SynapseConfig -> TargetConfig -> Config
buildConfigFromTarget wa = Config.buildConfigFromTarget (waOptions wa)

-- | Filter targets to those with "plugins" or "all" in generate list,
-- optionally pinning to a single named target (--target flag).
filterTargets :: WatchArgs -> Map Text TargetConfig -> Map Text TargetConfig
filterTargets watchArgs allTargets =
  let hasPlugins tc = "plugins" `elem` tcGenerate tc || "all" `elem` tcGenerate tc
  in case waTarget watchArgs of
    Just name -> maybe Map.empty (Map.singleton name) (Map.lookup name allTargets)
    Nothing   -> Map.filter hasPlugins allTargets

-- | Synthesize a SynapseConfig from CLI args alone (no config file)
synapseConfigFromArgs :: WatchArgs -> SynapseConfig
synapseConfigFromArgs watchArgs =
  defaultSynapseConfig { scBackend = Just (waBackend watchArgs) }

-- | Parse host and port from a WebSocket URL. Alias for 'Config.parseWsUrl'.
parseUrl :: Text -> (Text, Text)
parseUrl = Config.parseWsUrl
