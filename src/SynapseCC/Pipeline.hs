-- | Pipeline orchestration - running the full toolchain
module SynapseCC.Pipeline
  ( runPipeline
  , generateIR
  , generateCode
  ) where

import Control.Monad (when)
import Data.Aeson (FromJSON, eitherDecodeStrict, eitherDecodeFileStrict)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))

import SynapseCC.Benchmark (timeStep, loadBaseline, saveBaseline, baselinePath, reportBenchmarks)
import SynapseCC.Logging (logDebug, logInfo, logStep, logSuccess)
import SynapseCC.Types
import SynapseCC.Process
import SynapseCC.Discover
import qualified SynapseCC.Language as Language
import qualified SynapseCC.Cache as Cache
import SynapseCC.Cache (getCacheDir)

-- ============================================================================
-- Pipeline Orchestration
-- ============================================================================

-- | Run the complete pipeline
runPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runPipeline config tools = do
  let debug = optDebug (cfgOptions config)

  -- Step 0: Check cache (unless --force is set)
  cacheResult <- Cache.validateCache config tools
  case cacheResult of
    FullCacheHit -> do
      logDebug debug "Full cache hit (versions match)"
      -- Verify the output directory exists and contains at least one file
      let outputPath = optOutput (cfgOptions config)
      dirExists <- doesDirectoryExist outputPath
      files <- if dirExists
                 then listDirectory outputPath
                 else pure []
      if dirExists && not (null files)
        then do
          logDebug debug "  Using cached output"
          pure $ Right $ CompiledPath outputPath
        else do
          logDebug debug "  Cache hit but output directory missing or empty — regenerating"
          runFullPipeline config tools

    CacheMiss reason -> do
      logDebug debug $ "Cache miss: " <> T.pack (show reason)
      logDebug debug "  Regenerating..."
      runFullPipeline config tools

    PartialCacheHit valid invalid -> do
      let totalPlugins = length valid + length invalid
      logInfo $ T.pack (show (length invalid)) <> " of " <> T.pack (show totalPlugins)
              <> " plugins changed — regenerating (partial regen not yet supported)"
      -- TODO: Implement partial regeneration
      -- For now, do full regeneration
      runFullPipeline config tools

-- | Run the full pipeline without cache
runFullPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runFullPipeline config tools = do
  let debug  = optDebug (cfgOptions config)
      opts   = cfgOptions config
      Backend backendName = cfgBackend config
      targetName = case cfgTarget config of
        TypeScript -> "typescript"
        Python     -> "python"
        Rust       -> "rust"

  pipelineStart <- getCurrentTime
  cacheDir <- getCacheDir opts

  -- Step 1: Generate IR
  logStep "Generating IR..."
  (irResult, irMs) <- timeStep $ generateIR config tools
  case irResult of
    Left err -> pure $ Left err
    Right irPath -> do
      irBytes <- BS.readFile (unIRPath irPath)
      let pluginCount = case eitherDecodeStrict irBytes of
            Right (ir :: IRData) -> Map.size (irdPlugins ir)
            Left _               -> 0
      logSuccess $ "IR generated (" <> T.pack (show pluginCount) <> " plugins)"
      logDebug debug $ "  IR at " <> T.pack (unIRPath irPath)

      -- Step 2: Generate code
      logStep "Generating code..."
      (codeResult, codeMs) <- timeStep $ generateCode config tools irPath
      case codeResult of
        Left err -> pure $ Left err
        Right genPath -> do
          logSuccess "Code generated"
          logDebug debug $ "  Code at " <> T.pack (unGeneratedPath genPath)

          -- Step 3: Install dependencies (if enabled)
          (installResult, installMs) <- if optInstallDeps opts
            then do
              logStep "Installing dependencies..."
              (result, ms) <- timeStep $ Language.installDependencies (cfgTarget config) genPath debug
              case result of
                Right () -> logSuccess "Dependencies installed"
                Left _   -> pure ()
              pure (result, ms)
            else do
              logDebug debug "Skipping dependency installation (--no-install)"
              pure (Right (), 0)

          case installResult of
            Left err -> pure $ Left err
            Right () -> do

              -- Step 4: Build project (if enabled)
              (buildResult, buildMs) <- if optBuild opts
                then do
                  logStep "Building..."
                  (result, ms) <- timeStep $ Language.buildProject (cfgTarget config) genPath debug
                  case result of
                    Right _ -> logSuccess "Build passed"
                    Left _  -> pure ()
                  pure (result, ms)
                else do
                  logDebug debug "Skipping build (--no-build)"
                  pure (Right $ CompiledPath $ unGeneratedPath genPath, 0)

              case buildResult of
                Left err -> pure $ Left err
                Right compiledPath -> do

                  -- Step 5: Run tests (if enabled)
                  (testResult, testMs) <- if optRunTests opts
                    then do
                      logStep "Running tests..."
                      (result, ms) <- timeStep $ Language.runTests (cfgTarget config) genPath debug
                      case result of
                        Right () -> logSuccess "Tests passed"
                        Left _   -> pure ()
                      pure (result, ms)
                    else pure (Right (), 0)

                  case testResult of
                    Left err -> pure $ Left err
                    Right () -> do
                      writeCache config tools irPath compiledPath

                      -- Benchmarks
                      pipelineEnd <- getCurrentTime
                      let totalMs  = round (pipelineEnd `diffUTCTime'` pipelineStart * 1000) :: Int
                          steps    = Map.fromList $ filter (\(_, v) -> v > 0)
                                       [ ("ir_generation",       irMs)
                                       , ("code_generation",     codeMs)
                                       , ("install_dependencies", installMs)
                                       , ("build",               buildMs)
                                       , ("tests",               testMs)
                                       ]
                          ts       = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" pipelineEnd
                          bPath    = baselinePath cacheDir targetName backendName

                      reportBenchmarks bPath backendName targetName ts steps totalMs

                      pure $ Right compiledPath

diffUTCTime' :: UTCTime -> UTCTime -> Double
diffUTCTime' t1 t0 = realToFrac (t1 `diffUTCTime` t0)

-- | Write cache manifests after successful generation
writeCache :: Config -> ToolLocations -> IRPath -> CompiledPath -> IO ()
writeCache config tools irPath _compiledPath = do
  let debug = optDebug (cfgOptions config)
      outputDir = optOutput (cfgOptions config)
      synapseVer    = toolSynapseVersion tools
      hubCodegenVer = toolHubCodegenVersion tools
  logDebug debug "Writing cache manifests..."

  -- Read file hashes from .codegen-metadata.json
  fileHashesMap <- readFileHashes outputDir debug

  -- Read IR to extract plugin hashes
  irPluginCaches <- readIRPluginHashes irPath debug

  -- Write IR cache manifest with plugin hashes
  Cache.writeIRCacheManifest (cfgOptions config) (cfgBackend config) irPluginCaches synapseVer

  -- Write code cache with file hashes
  -- Convert flat file hash map to per-plugin structure
  let pluginCaches = buildPluginCaches fileHashesMap
  Cache.writeCodeCacheManifest (cfgOptions config) (cfgBackend config) (cfgTarget config) pluginCaches synapseVer hubCodegenVer

  logDebug debug "  Cache manifests written"

-- | Read file hashes from .codegen-metadata.json
readFileHashes :: FilePath -> Bool -> IO (Map.Map Text Text)
readFileHashes outputDir debug = do
  let metadataPath = outputDir </> ".codegen-metadata.json"
  exists <- doesFileExist metadataPath
  if not exists
    then do
      logDebug debug "  .codegen-metadata.json not found, skipping file hashes"
      pure Map.empty
    else do
      result <- eitherDecodeFileStrict metadataPath
      case result of
        Left err -> do
          logDebug debug $ "  Failed to parse metadata: " <> T.pack err
          pure Map.empty
        Right (metadata :: CodegenMetadata) -> do
          logDebug debug $ "  Read " <> T.pack (show (Map.size (ciFileHashes (cmCache metadata)))) <> " file hashes"
          pure $ ciFileHashes (cmCache metadata)

-- | Read IR plugin hashes from ir.json (now at cache path)
readIRPluginHashes :: IRPath -> Bool -> IO (Map.Map Text IRPluginCache)
readIRPluginHashes (IRPath irFilePath) debug = do
  exists <- doesFileExist irFilePath
  if not exists
    then do
      logDebug debug "  ir.json not found, skipping IR plugin hashes"
      pure Map.empty
    else do
      result <- eitherDecodeFileStrict irFilePath
      case result of
        Left err -> do
          logDebug debug $ "  Failed to parse IR: " <> T.pack err
          pure Map.empty
        Right (irData :: IRData) -> do
          let pluginHashes = fromMaybe Map.empty (irdPluginHashes irData)
              pluginCaches = Map.mapWithKey (buildIRPluginCache pluginHashes) (irdPlugins irData)
          logDebug debug $ "  Extracted hashes for " <> T.pack (show (Map.size pluginCaches)) <> " plugins"
          pure pluginCaches

-- | Build an IRPluginCache entry from plugin info and hashes
buildIRPluginCache :: Map.Map Text PluginHashInfo -> Text -> [Text] -> IRPluginCache
buildIRPluginCache hashMap pluginName _methods =
  case Map.lookup pluginName hashMap of
    Just hashes -> IRPluginCache
      { ipcIRHash = ""  -- TODO: Compute IR hash (WS2)
      , ipcSchemaHash = phiHash hashes
      , ipcSelfHash = phiSelfHash hashes
      , ipcChildrenHash = phiChildrenHash hashes
      , ipcDependencies = []  -- TODO: Extract dependencies from IR
      , ipcCachedAt = ""  -- Will be set by writeIRCacheManifest
      }
    Nothing -> IRPluginCache
      { ipcIRHash = ""
      , ipcSchemaHash = ""  -- No hash info available
      , ipcSelfHash = ""
      , ipcChildrenHash = ""
      , ipcDependencies = []
      , ipcCachedAt = ""
      }

-- | Build per-plugin cache entries from flat file hash map
-- For now, group all files into a single "default" plugin entry
-- This will be improved when we implement per-plugin hash tracking
buildPluginCaches :: Map.Map Text Text -> Map.Map Text CodePluginCache
buildPluginCaches fileHashes =
  if Map.null fileHashes
    then Map.empty
    else Map.singleton "default" CodePluginCache
      { cpcIRHash = ""  -- Will be populated when WS1 is complete
      , cpcFileHashes = fileHashes
      , cpcCachedAt = ""  -- Will be set by writeCodeCacheManifest
      }

-- ============================================================================
-- IR Generation
-- ============================================================================

-- | Generate IR using synapse
generateIR :: Config -> ToolLocations -> IO (Either SynapseCCError IRPath)
generateIR config tools = do
  let debug = optDebug (cfgOptions config)
      synapsePath = toolPathToFilePath (toolSynapse tools)
      Backend backendName = cfgBackend config
      outputDir = optOutput (cfgOptions config)
      opts = cfgOptions config

  -- Compute IR file path in the cache directory:
  --   <cacheDir>/synapse/ir/<backend>/ir.json
  cacheDir <- getCacheDir opts
  let irDir  = cacheDir </> "synapse" </> "ir" </> T.unpack backendName
      irFile = irDir </> "ir.json"

  -- Ensure output and IR cache directories exist
  createDirectoryIfMissing True outputDir
  createDirectoryIfMissing True irDir

  -- Build synapse command: synapse -H <host> -P <port> -i <backend> --generator-info synapse-cc:version
  let host = cfgHost config
      port = cfgPort config
      generatorInfo = "synapse-cc:" <> synapseCCVersion
      args = [ "-H", T.unpack host
             , "-P", T.unpack port
             , "--generator-info", T.unpack generatorInfo
             , "-i"
             , T.unpack backendName
             ]

  -- Run synapse
  result <- runProcess synapsePath args Nothing debug

  case prExitCode result of
    ExitSuccess -> do
      -- Write IR to cache path
      BS.writeFile irFile (TE.encodeUtf8 $ prStdout result)

      -- Validate IR by trying to parse it
      irBytes <- BS.readFile irFile
      case eitherDecodeStrict irBytes of
        Left parseErr -> pure $ Left $ InvalidIR $ T.pack parseErr
        Right (_ :: IRData) -> pure $ Right $ IRPath irFile

    ExitFailure code -> do
      pure $ Left $ SynapseError (prStderr result) code

-- | IR structure for reading plugin hashes
-- We only need the fields relevant for caching
data IRData = IRData
  { irdVersion      :: !Text
  , irdPlugins      :: !(Map.Map Text [Text])
  , irdPluginHashes :: !(Maybe (Map.Map Text PluginHashInfo))
  } deriving stock (Show, Generic)

instance FromJSON IRData where
  parseJSON = Aeson.withObject "IRData" $ \o -> IRData
    <$> o Aeson..: "irVersion"
    <*> o Aeson..: "irPlugins"
    <*> o Aeson..:? "irPluginHashes"

-- | Plugin hash information from IR
data PluginHashInfo = PluginHashInfo
  { phiHash         :: !Text
  , phiSelfHash     :: !Text
  , phiChildrenHash :: !Text
  } deriving stock (Show, Generic)
    deriving anyclass (FromJSON)

-- ============================================================================
-- Code Generation
-- ============================================================================

-- | Generate code using hub-codegen
generateCode :: Config -> ToolLocations -> IRPath -> IO (Either SynapseCCError GeneratedPath)
generateCode config tools irPath = do
  let debug = optDebug (cfgOptions config)
      hubCodegenPath = toolPathToFilePath (toolHubCodegen tools)
      outputDir = optOutput (cfgOptions config)
      target = cfgTarget config
  -- Build hub-codegen command
  let targetArg = case target of
        TypeScript -> "typescript"
        Python -> "python"
        Rust -> "rust"

      args =
        [ "--target", targetArg
        , "--output", outputDir
        , unIRPath irPath
        ]

  -- Run hub-codegen
  result <- runProcess hubCodegenPath args Nothing debug

  case prExitCode result of
    ExitSuccess -> do
      pure $ Right $ GeneratedPath outputDir

    ExitFailure code -> do
      pure $ Left $ HubCodegenError (prStderr result) code
