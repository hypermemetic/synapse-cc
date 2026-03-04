-- | Pipeline orchestration - running the full toolchain
module SynapseCC.Pipeline
  ( runPipeline
  , generateIR
  , generateCode
  ) where

import Data.Aeson (FromJSON, eitherDecodeStrict, eitherDecodeFileStrict)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))

import SynapseCC.Logging (logDebug, logStep, logSuccess)
import SynapseCC.Types
import SynapseCC.Process
import SynapseCC.Discover
import qualified SynapseCC.Language as Language
import qualified SynapseCC.Cache as Cache

-- ============================================================================
-- Pipeline Orchestration
-- ============================================================================

-- | Run the complete pipeline
runPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runPipeline config tools = do
  let debug = optDebug (cfgOptions config)

  -- Step 0: Check cache (unless --force is set)
  cacheResult <- Cache.validateCache config
  case cacheResult of
    FullCacheHit -> do
      logDebug debug "Full cache hit (versions match)"
      logDebug debug "  Using cached output"
      -- TODO: Copy cached code to output directory if needed
      let outputPath = optOutput (cfgOptions config)
      pure $ Right $ CompiledPath outputPath

    CacheMiss reason -> do
      logDebug debug $ "Cache miss: " <> T.pack (show reason)
      logDebug debug "  Regenerating..."
      runFullPipeline config tools

    PartialCacheHit valid invalid -> do
      logDebug debug "Partial cache hit"
      logDebug debug $ "  Valid plugins: " <> T.pack (show valid)
      logDebug debug $ "  Invalid plugins: " <> T.pack (show invalid)
      logDebug debug "  Regenerating invalid plugins..."
      -- TODO: Implement partial regeneration
      -- For now, do full regeneration
      runFullPipeline config tools

-- | Run the full pipeline without cache
runFullPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runFullPipeline config tools = do
  let debug = optDebug (cfgOptions config)

  -- Step 1: Generate IR
  logStep "Generating IR..."
  irResult <- generateIR config tools
  case irResult of
    Left err -> pure $ Left err
    Right irPath -> do
      -- Count plugins for progress message
      irBytes <- BS.readFile (unIRPath irPath)
      let pluginCount = case eitherDecodeStrict irBytes of
            Right (ir :: IRData) -> Map.size (irdPlugins ir)
            Left _               -> 0
      logSuccess $ "IR generated (" <> T.pack (show pluginCount) <> " plugins)"
      logDebug debug $ "  IR at " <> T.pack (unIRPath irPath)

      -- Step 2: Generate code
      logStep "Generating code..."
      codeResult <- generateCode config tools irPath
      case codeResult of
        Left err -> pure $ Left err
        Right genPath -> do
          logSuccess "Code generated"
          logDebug debug $ "  Code at " <> T.pack (unGeneratedPath genPath)

          -- Step 3: Install dependencies (if enabled)
          installResult <- if optInstallDeps (cfgOptions config)
            then do
              logStep "Installing dependencies..."
              result <- Language.installDependencies (cfgTarget config) genPath debug
              case result of
                Right () -> logSuccess "Dependencies installed"
                Left _   -> pure ()
              pure result
            else do
              logDebug debug "Skipping dependency installation (--no-install)"
              pure $ Right ()

          case installResult of
            Left err -> pure $ Left err
            Right () -> do

              -- Step 4: Build project (if enabled)
              buildResult <- if optBuild (cfgOptions config)
                then do
                  logStep "Building..."
                  result <- Language.buildProject (cfgTarget config) genPath debug
                  case result of
                    Right _ -> logSuccess "Build passed"
                    Left _  -> pure ()
                  pure result
                else do
                  logDebug debug "Skipping build (--no-build)"
                  pure $ Right $ CompiledPath $ unGeneratedPath genPath

              case buildResult of
                Left err -> pure $ Left err
                Right compiledPath -> do

                  -- Step 5: Run tests (if enabled)
                  if optRunTests (cfgOptions config)
                    then do
                      logStep "Running tests..."
                      testResult <- Language.runTests (cfgTarget config) genPath debug
                      case testResult of
                        Left err -> pure $ Left err
                        Right () -> do
                          logSuccess "Tests passed"
                          writeCache config compiledPath
                          pure $ Right compiledPath
                    else do
                      writeCache config compiledPath
                      pure $ Right compiledPath

-- | Write cache manifests after successful generation
writeCache :: Config -> CompiledPath -> IO ()
writeCache config _compiledPath = do
  let debug = optDebug (cfgOptions config)
      outputDir = optOutput (cfgOptions config)
  logDebug debug "Writing cache manifests..."

  -- Read file hashes from .codegen-metadata.json
  fileHashesMap <- readFileHashes outputDir debug

  -- Read IR to extract plugin hashes
  irPluginCaches <- readIRPluginHashes outputDir debug

  -- Write IR cache manifest with plugin hashes
  Cache.writeIRCacheManifest (cfgOptions config) (cfgBackend config) irPluginCaches

  -- Write code cache with file hashes
  -- Convert flat file hash map to per-plugin structure
  let pluginCaches = buildPluginCaches fileHashesMap
  Cache.writeCodeCacheManifest (cfgOptions config) (cfgBackend config) (cfgTarget config) pluginCaches

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

-- | Read IR plugin hashes from ir.json
readIRPluginHashes :: FilePath -> Bool -> IO (Map.Map Text IRPluginCache)
readIRPluginHashes outputDir debug = do
  let irPath = outputDir </> "ir.json"
  exists <- doesFileExist irPath
  if not exists
    then do
      logDebug debug "  ir.json not found, skipping IR plugin hashes"
      pure Map.empty
    else do
      result <- eitherDecodeFileStrict irPath
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
      irFile = outputDir </> "ir.json"

  -- Ensure output directory exists
  createDirectoryIfMissing True outputDir

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
      -- Write IR to file
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
