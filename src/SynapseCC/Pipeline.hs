-- | Pipeline orchestration - running the full toolchain
module SynapseCC.Pipeline
  ( runPipeline
  , generateIR
  , generateCode
  ) where

import Control.Monad (when, unless, forM_)
import Data.Aeson (FromJSON, eitherDecodeStrict, eitherDecodeFileStrict)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory)
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
import qualified SynapseCC.Merge as Merge

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

-- | Minimal starter package.json written when none exists in the output directory.
-- Includes standard scripts for the generated client; users own the name/version.
-- Dependencies are NOT listed here — they are added via `pm add` by addDependencies.
-- | Marker field written into the starter package.json.
-- Presence of this field in the cwd package.json tells synapse-cc that IT
-- created the file (standalone mode), so scaffolding files (tsconfig, test/)
-- continue to be regenerated on subsequent runs.  Users who remove this field
-- opt in to integration mode — synapse-cc will stop managing those files.
synapseCCMarker :: Text
synapseCCMarker = "\"_generatedBy\": \"synapse-cc\""

-- | Minimal starter package.json written when none exists in the output directory.
-- Includes standard scripts for the generated client; users own the name/version.
-- Dependencies are NOT listed here — they are added via `pm add` by addDependencies.
starterPackageJson :: Text
starterPackageJson =
  "{\n\
  \  \"name\": \"@plexus/client\",\n\
  \  \"version\": \"0.0.1\",\n\
  \  \"type\": \"module\",\n\
  \  \"private\": true,\n\
  \  \"_generatedBy\": \"synapse-cc\",\n\
  \  \"scripts\": {\n\
  \    \"test\": \"bun test\",\n\
  \    \"typecheck\": \"bun x tsc --noEmit\"\n\
  \  }\n\
  \}\n"

-- | Generate tsconfig.json for the synapse-cc managed output directory.
-- Excludes test/ so bun:test imports don't cause tsc errors — bun handles
-- test files natively and doesn't need tsconfig to know about bun:test.
generateTsconfig :: TransportType -> Text
generateTsconfig transport =
  let typeConfig = case transport of
        BrowserTransport -> "\"lib\": [\"ES2022\", \"DOM\"]"
        WsTransport      -> "\"types\": [\"node\"]"
  in T.unlines
    [ "{"
    , "  \"compilerOptions\": {"
    , "    \"target\": \"ES2022\","
    , "    \"module\": \"ESNext\","
    , "    \"moduleResolution\": \"bundler\","
    , "    \"strict\": true,"
    , "    \"skipLibCheck\": true,"
    , "    \"noEmit\": true,"
    , "    " <> typeConfig
    , "  },"
    , "  \"include\": [\"*.ts\"]"
    , "}"
    ]

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
      outputDir = optOutput opts

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
        Right out -> do
          logSuccess $ "Code generated (" <> T.pack (show (Map.size (coFiles out))) <> " files)"

          -- Package manager commands always run in cwd (the project root the user
          -- invoked synapse-cc from), not in the output subdirectory.
          -- Write a starter package.json there only when none exists (standalone use).
          cwd <- getCurrentDirectory
          let pmPath = GeneratedPath cwd
          let pkgJsonPath = cwd </> "package.json"
          pkgExists <- doesFileExist pkgJsonPath

          -- Integration mode: cwd has a package.json that we did NOT create.
          -- We detect this with a "_generatedBy" marker written into our starter.
          -- Without the marker the file belongs to the host project; strip scaffolding
          -- (tsconfig.json, test/) that would pollute the host project's source tree.
          -- Users can remove the marker to opt-in to integration mode at any time.
          isOurStarter <- if pkgExists
            then (synapseCCMarker `T.isInfixOf`) <$> TIO.readFile pkgJsonPath
            else pure False
          let isIntegration = pkgExists && not isOurStarter
          let scaffolding k _ = "test/" `T.isPrefixOf` k

          -- Apply three-way merge: write safe files, skip user-modified ones.
          -- package.json and tsconfig.json are always excluded from the merge:
          --   package.json — managed via `pm add` in the project root
          --   tsconfig.json — synapse-cc writes its own (see below)
          -- In integration mode, also exclude test/* (host project owns those).
          -- With --force, skip cached hashes so all files are written fresh.
          cachedHashes <- if optForce opts then pure Map.empty else getCachedFileHashes config
          let filesToMerge = (if isIntegration then Map.filterWithKey (fmap not . scaffolding) else id)
                           $ Map.delete "package.json"
                           $ Map.delete "tsconfig.json"
                           $ coFiles out
          mergeResult  <- Merge.applyMerge filesToMerge (coFileHashes out) cachedHashes outputDir

          -- Write ir.json to output dir as a reference artifact
          irContent <- BS.readFile (unIRPath irPath)
          BS.writeFile (outputDir </> "ir.json") irContent

          -- Log skipped files (user modifications preserved)
          let skipped = Merge.mrSkipped mergeResult
          unless (null skipped) $ do
            logInfo $ "  ⚠  " <> T.pack (show (length skipped))
                    <> " file(s) skipped (user modifications preserved)"
            when debug $ forM_ skipped $ \f ->
              logDebug debug $ "      - " <> f

          let genPath = GeneratedPath outputDir

          unless pkgExists $ do
            logDebug debug "  Writing starter package.json"
            TIO.writeFile pkgJsonPath starterPackageJson

          -- Write synapse-cc's tsconfig to the output dir (standalone mode only).
          -- Integration mode: host project owns tsconfig at its root; we don't touch it.
          -- The tsconfig only covers *.ts (not test/) so tsc never sees bun:test imports.
          unless isIntegration $ do
            logDebug debug "  Writing tsconfig.json"
            TIO.writeFile (outputDir </> "tsconfig.json") (generateTsconfig (optTransport opts))

          -- Step 3: Install dependencies (if enabled)
          -- In integration mode, only add runtime deps — the host project owns dev tooling.
          let depsToAdd    = coDependencies out
              devDepsToAdd = if isIntegration then Map.empty else coDevDependencies out
          (installResult, installMs) <- if optInstallDeps opts
            then do
              logStep "Adding dependencies..."
              (addResult, addMs) <- timeStep $ Language.addDependencies
                pmPath
                depsToAdd
                devDepsToAdd
                debug
              case addResult of
                Right () -> pure ()
                Left _   -> pure ()
              case addResult of
                Left err -> pure (Left err, addMs)
                Right () -> do
                  logStep "Installing dependencies..."
                  (result, ms) <- timeStep $ Language.installDependencies (cfgTarget config) pmPath debug
                  case result of
                    Right () -> logSuccess "Dependencies installed"
                    Left _   -> pure ()
                  pure (result, addMs + ms)
            else do
              logDebug debug "Skipping dependency installation (--no-install)"
              pure (Right (), 0)

          case installResult of
            Left err -> pure $ Left err
            Right () -> do

              -- Step 4: Build project (if enabled)
              -- In integration mode tsconfig.json is not written to the output dir;
              -- the host project's own build system handles compilation.
              (buildResult, buildMs) <- if optBuild opts && not isIntegration
                then do
                  logStep "Building..."
                  (result, ms) <- timeStep $ Language.buildProject (cfgTarget config) genPath debug
                  case result of
                    Right _ -> logSuccess "Build passed"
                    Left _  -> pure ()
                  pure (result, ms)
                else do
                  if isIntegration
                    then logDebug debug "Skipping build (integration mode — compile via your project's build system)"
                    else logDebug debug "Skipping build (--no-build)"
                  pure (Right $ CompiledPath $ unGeneratedPath genPath, 0)

              case buildResult of
                Left err -> pure $ Left err
                Right compiledPath -> do

                  -- Step 5: Run tests (if enabled)
                  -- In integration mode test/ is not written to the output dir.
                  (testResult, testMs) <- if optRunTests opts && not isIntegration
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
                      writeCache config tools irPath compiledPath out

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
writeCache :: Config -> ToolLocations -> IRPath -> CompiledPath -> CodegenOutput -> IO ()
writeCache config tools irPath _compiledPath codegenOutput = do
  let debug         = optDebug (cfgOptions config)
      synapseVer    = toolSynapseVersion tools
      hubCodegenVer = coHubCodegenVersion codegenOutput
  logDebug debug "Writing cache manifests..."

  -- Read IR to extract plugin hashes
  irPluginCaches <- readIRPluginHashes irPath debug

  -- Write IR cache manifest with plugin hashes
  Cache.writeIRCacheManifest (cfgOptions config) (cfgBackend config) irPluginCaches synapseVer

  -- Write code cache manifest using file hashes from CodegenOutput
  let pluginCaches = Map.singleton "default" CodePluginCache
        { cpcIRHash     = ""
        , cpcFileHashes = coFileHashes codegenOutput
        , cpcCachedAt   = ""
        }
  Cache.writeCodeCacheManifest (cfgOptions config) (cfgBackend config) (cfgTarget config)
    pluginCaches synapseVer hubCodegenVer

  logDebug debug "  Cache manifests written"

-- | Read the cached file hashes from the code cache manifest for three-way merge.
getCachedFileHashes :: Config -> IO (Map.Map Text Text)
getCachedFileHashes config = do
  result <- Cache.readCodeCacheManifest (cfgOptions config) (cfgBackend config) (cfgTarget config)
  pure $ case result of
    Left _         -> Map.empty
    Right manifest -> maybe Map.empty cpcFileHashes $ Map.lookup "default" (ccmPlugins manifest)

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
      { ipcIRHash       = ""
      , ipcSchemaHash   = phiHash hashes
      , ipcSelfHash     = phiSelfHash hashes
      , ipcChildrenHash = phiChildrenHash hashes
      , ipcDependencies = []
      , ipcCachedAt     = ""
      }
    Nothing -> IRPluginCache
      { ipcIRHash       = ""
      , ipcSchemaHash   = ""
      , ipcSelfHash     = ""
      , ipcChildrenHash = ""
      , ipcDependencies = []
      , ipcCachedAt     = ""
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

-- | Generate code using hub-codegen, returning parsed JSON output
generateCode :: Config -> ToolLocations -> IRPath -> IO (Either SynapseCCError CodegenOutput)
generateCode config tools irPath = do
  let debug          = optDebug (cfgOptions config)
      hubCodegenPath = toolPathToFilePath (toolHubCodegen tools)
      opts           = cfgOptions config
      target         = cfgTarget config
      targetArg      = case target of
        TypeScript -> "typescript"
        Python     -> "python"
        Rust       -> "rust"
      args =
        [ "--target",           targetArg
        , "--output-format",    "json"
        , "--transport", case optTransport opts of
            WsTransport      -> "ws"
            BrowserTransport -> "browser"
        , unIRPath irPath
        ]

  result <- runProcess hubCodegenPath args Nothing debug

  case prExitCode result of
    ExitSuccess -> do
      let stdoutBytes = TE.encodeUtf8 (prStdout result)
      case eitherDecodeStrict stdoutBytes of
        Left parseErr -> pure $ Left $ HubCodegenError (T.pack parseErr) 0
        Right out     -> pure $ Right out
    ExitFailure code ->
      pure $ Left $ HubCodegenError (prStderr result) code
