-- | Pipeline orchestration - running the full toolchain
module SynapseCC.Pipeline
  ( runPipeline
  , runBuildFromConfig
  , generateIR
  , generateCode
  , formatSynapseError
  ) where

import Control.Exception (try, SomeException)
import Control.Monad (when, unless, forM_, forM)
import Data.Aeson (FromJSON, eitherDecodeStrict, eitherDecodeFileStrict)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
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
import System.FilePath ((</>), splitPath)

import Synapse.Monad (initEnv, runSynapseM, SynapseError(..))
import Synapse.IR.Builder (buildIR)
import qualified Synapse.Log as Log
import qualified Katip

import SynapseCC.Benchmark (timeStep, baselinePath, reportBenchmarks)
import SynapseCC.Config (buildConfigFromTarget)
import SynapseCC.Logging (logDebug, logInfo, logStep, logSuccess)
import SynapseCC.Types
import SynapseCC.Process
import SynapseCC.Discover
import qualified SynapseCC.Language as Language
import qualified SynapseCC.Cache as Cache
import SynapseCC.Cache (getCacheDir)
import qualified SynapseCC.Merge as Merge
import qualified SynapseCC.Lock as Lock
import qualified SynapseCC.Auth as Auth
import qualified SynapseCC.RegistryResolve as Registry

-- ============================================================================
-- Pipeline Orchestration
-- ============================================================================

-- | Run the complete pipeline
runPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runPipeline config tools = do
  let debug = optDebug (cfgOptions config)

  -- SAFE-4 (degraded mode): plexus-core does not yet expose its toolchain
  -- version (see SAFE-S01 spike). Warn once per build that version-gating
  -- is inactive until SAFE-S02 lands.
  logDebug debug "  SAFE-4: version-gating inactive (plexus-core does not expose toolchain version; see SAFE-S02)"

  -- Step 0: Check cache (unless --force is set)
  cacheResult <- Cache.validateCache config tools
  case cacheResult of
    FullCacheHit -> do
      logDebug debug "Full cache hit (versions match)"
      let outputPath = optOutput (cfgOptions config)
      -- If synapse.lock has an entry for this target, verify the live irHash
      -- before skipping.  This catches dynamic backends (e.g. fidget-spinner)
      -- where the schema can change without a toolchain version bump.
      lockResult <- Lock.readSynapseLock
      case lockResult >>= Lock.lookupLockTarget outputPath of
        Nothing ->
          -- No lock entry — fall through to directory existence check
          useCachedOutput debug outputPath
        Just lt -> do
          logDebug debug "  Checking live irHash against synapse.lock..."
          irCheckResult <- generateIR config tools
          case irCheckResult of
            Left _ -> do
              -- Backend unreachable — use cached output gracefully (offline mode)
              logDebug debug "  Cannot reach backend — using cached output"
              useCachedOutput debug outputPath
            Right (IRPath irFile) -> do
              irBytes <- BS.readFile irFile
              -- Use the IR's own irHash field (content-stable, excludes timestamps).
              let liveHash = case eitherDecodeStrict irBytes of
                    Right (irData :: IRData) -> fromMaybe "" (irdIrHash irData)
                    Left _                   -> Merge.computeFileHash (TE.decodeUtf8 irBytes)
              if liveHash == Lock.ltIrHash lt
                then do
                  logDebug debug $ "  irHash unchanged (" <> T.take 8 liveHash <> "...) — using cache"
                  useCachedOutput debug outputPath
                else do
                  logDebug debug $ "  irHash changed: " <> T.take 8 (Lock.ltIrHash lt)
                                <> " → " <> T.take 8 liveHash
                  runFullPipeline config tools
      where
        useCachedOutput dbg outPath = do
          dirExists <- doesDirectoryExist outPath
          files <- if dirExists then listDirectory outPath else pure []
          if dirExists && not (null files)
            then do
              logDebug dbg "  Using cached output"
              pure $ Right $ CompiledPath outPath
            else do
              logDebug dbg "  Cache hit but output directory missing or empty — regenerating"
              runFullPipeline config tools

    CacheMiss reason -> do
      logDebug debug $ "Cache miss: " <> T.pack (show reason)
      logDebug debug "  Regenerating..."
      runFullPipeline config tools

    PartialCacheHit valid invalid -> do
      let totalPlugins = length valid + length invalid
      logInfo $ T.pack (show (length invalid)) <> " of " <> T.pack (show totalPlugins)
              <> " plugins changed — regenerating"
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

-- | Marker present in package.json files generated by hub-codegen.
-- Used alongside synapseCCMarker to detect generated (standalone) output directories.
generatedByMarker :: Text
generatedByMarker = "\"_generatedBy\""

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

-- | Generate tsconfig.json for integration mode (generated code inside a host project).
-- Enables project references (composite, declaration, declarationMap) so the host
-- project can reference the generated directory as a sub-project with its own settings.
generateIntegrationTsconfig :: Text
generateIntegrationTsconfig = T.unlines
    [ "{"
    , "  \"compilerOptions\": {"
    , "    \"target\": \"ES2022\","
    , "    \"module\": \"ES2022\","
    , "    \"moduleResolution\": \"bundler\","
    , "    \"composite\": true,"
    , "    \"declaration\": true,"
    , "    \"declarationMap\": true,"
    , "    \"strict\": true,"
    , "    \"skipLibCheck\": true,"
    , "    \"esModuleInterop\": true,"
    , "    \"outDir\": \"../dist/generated\","
    , "    \"rootDir\": \".\""
    , "  },"
    , "  \"include\": [\"**/*.ts\"]"
    , "}"
    ]

-- | Run the full pipeline without cache
runFullPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runFullPipeline config tools = do
  let debug  = optDebug (cfgOptions config)
      opts   = cfgOptions config
      Backend backendName = cfgBackend config
      targetName = targetToText (cfgTarget config)
      outputDir = optOutput opts

  pipelineStart <- getCurrentTime
  cacheDir <- getCacheDir opts

  -- Step 1: Read schema from backend
  logStep "Reading schema..."
  (irResult, irMs) <- timeStep $ generateIR config tools
  case irResult of
    Left err -> pure $ Left err
    Right irPath -> do
      irBytes <- BS.readFile (unIRPath irPath)
      let pluginCount = case eitherDecodeStrict irBytes of
            Right (ir :: IRData) -> Map.size (irdPlugins ir)
            Left _               -> 0
      logSuccess $ "Schema ready (" <> T.pack (show pluginCount) <> " plugins)"
      logDebug debug $ "  IR at " <> T.pack (unIRPath irPath)

      -- Step 2: Generate code
      logStep "Generating code..."
      (codeResult, codeMs) <- timeStep $ generateCode config tools irPath Nothing
      case codeResult of
        Left err -> pure $ Left err
        Right out -> do
          logSuccess $ "Code generated (" <> T.pack (show (Map.size (coFiles out))) <> " files)"

          -- Detect standalone vs integration mode.
          --
          -- Check the OUTPUT directory first: if it already has a package.json with a
          -- "_generatedBy" field, hub-codegen (or a prior synapse-cc run) wrote it
          -- → standalone, regardless of what the CWD contains.
          --
          -- If outputDir has no package.json, fall back to checking the CWD: if the CWD
          -- has a package.json without our marker, the user ran synapse-cc from inside a
          -- host project → integration mode (Tauri, monorepo, etc.).
          --
          -- Integration mode strips test/ scaffolding, skips devDeps, and skips
          -- build/test steps — the host project owns those concerns.
          cwd <- getCurrentDirectory
          let pmPath    = GeneratedPath cwd
              cwdPkgPath = cwd </> "package.json"
              outPkgJsonPath = outputDir </> "package.json"
          outPkgExists <- doesFileExist outPkgJsonPath
          isIntegration <-
            if outPkgExists
              then do
                -- outputDir has a package.json — if it has _generatedBy it's ours (standalone)
                content <- TIO.readFile outPkgJsonPath
                pure $ not (generatedByMarker `T.isInfixOf` content)
              else do
                -- outputDir has no package.json — check CWD for host project
                cwdPkgExists <- doesFileExist cwdPkgPath
                if not cwdPkgExists
                  then pure False
                  else do
                    cwdContent <- TIO.readFile cwdPkgPath
                    pure $ not (synapseCCMarker `T.isInfixOf` cwdContent)
          when isIntegration $
            logInfo "  Integration mode — build and test steps skipped"
          let scaffolding k _ = "test/" `T.isPrefixOf` k

          -- Apply three-way merge: write safe files, skip user-modified ones.
          -- tsconfig.json is always excluded: synapse-cc writes its own (see below).
          -- package.json is excluded in integration mode (host project owns it);
          --   in standalone mode it goes through the merge so script changes are applied.
          -- In integration mode, also exclude test/* (host project owns those).
          -- With --force, skip cached hashes so all files are written fresh.
          cachedHashes <- if optForce opts then pure Map.empty else getCachedFileHashes config
          let filesToMerge = (if isIntegration then Map.filterWithKey (fmap not . scaffolding) else id)
                           $ (if isIntegration then Map.delete "package.json" else id)
                           $ Map.delete "tsconfig.json"
                           $ coFiles out
          mergeResult  <- Merge.applyMerge filesToMerge (coFileHashes out) cachedHashes outputDir

          -- Remove stale generated files (plugins removed from backend).
          -- Only deletes files whose on-disk hash still matches the cached hash
          -- (i.e. the user hasn't modified them). Empty directories are pruned.
          deleted <- Merge.cleanRemovedFiles cachedHashes (coFileHashes out) outputDir
          unless (null deleted) $ do
            logInfo $ "  🗑  " <> T.pack (show (length deleted))
                    <> " stale file(s) removed (plugin removed from backend)"
            when debug $ forM_ deleted $ \f ->
              logDebug debug $ "      - " <> f

          -- Write ir.json to output dir as a reference artifact
          irContent <- BS.readFile (unIRPath irPath)
          BS.writeFile (outputDir </> "ir.json") irContent

          -- Log smart-merged files (new content added, user modifications preserved)
          let merged = Merge.mrMerged mergeResult
          unless (null merged) $ do
            logInfo $ "  ✓ " <> T.pack (show (length merged))
                    <> " file(s) smart-merged (new content added, user modifications preserved)"
            when debug $ forM_ merged $ \f ->
              logDebug debug $ "      - " <> f

          -- Log skipped files (user modifications preserved)
          let skipped = Merge.mrSkipped mergeResult
          unless (null skipped) $ do
            logInfo $ "  ⚠  " <> T.pack (show (length skipped))
                    <> " file(s) skipped (user modifications preserved)"
            when debug $ forM_ skipped $ \f ->
              logDebug debug $ "      - " <> f

          let genPath = GeneratedPath outputDir

          -- Write synapse-cc's tsconfig to the output dir.
          -- Standalone mode: tight config (noEmit, transport-specific types).
          -- Integration mode: project-references config (composite, declaration).
          do logDebug debug "  Writing tsconfig.json"
             let tsconfig = if isIntegration
                              then generateIntegrationTsconfig
                              else generateTsconfig (optTransport opts)
             TIO.writeFile (outputDir </> "tsconfig.json") tsconfig

          -- Step 3: Install dependencies (if enabled)
          -- Standalone: deps go into the generated dir (genPath) — it owns its own package.json.
          -- Integration: deps go into the host project root (pmPath) since there's no generated package.json.
          let depsToAdd    = coDependencies out
              devDepsToAdd = if isIntegration then Map.empty else coDevDependencies out
              depPath      = if isIntegration then pmPath else genPath
          (installResult, installMs) <- if optInstallDeps opts
            then do
              (addResult, addMs) <- timeStep $ Language.addDependencies
                depPath
                depsToAdd
                devDepsToAdd
                debug
              case addResult of
                Left err -> pure (Left err, addMs)
                Right added -> do
                  -- Run installDependencies if new packages were added OR node_modules is absent
                  nodeModulesExists <- doesDirectoryExist
                    (unGeneratedPath depPath </> "node_modules")
                  if not added && nodeModulesExists
                    then pure (Right (), addMs)
                    else do
                      when added $ logSuccess "Dependencies updated"
                      logStep "Installing dependencies..."
                      (result, ms) <- timeStep $ Language.installDependencies (cfgTarget config) depPath debug
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
                      -- Patch file hashes: replace hashes for smart-merged files
                      -- with their merged hashes so subsequent runs see them as SafeToUpdate
                      let patchedHashes = Map.union (Merge.mrMergedHashes mergeResult) (coFileHashes out)
                          patchedOut = out { coFileHashes = patchedHashes }
                      writeCache config tools irPath compiledPath patchedOut

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

                      when debug $ reportBenchmarks bPath backendName targetName ts steps totalMs

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

  -- Write synapse.lock (project-level, committed to git)
  irBytes <- BS.readFile (unIRPath irPath)
  -- Use the IR's own irHash field (content-stable, no timestamps).
  -- Fall back to hashing the raw bytes only if the field is absent.
  let parsedIrHash = case eitherDecodeStrict irBytes of
        Right (irData :: IRData) -> fromMaybe "" (irdIrHash irData)
        Left _                   -> ""
      irHash    = if T.null parsedIrHash
                    then Merge.computeFileHash (TE.decodeUtf8 irBytes)
                    else parsedIrHash
      outputDir = optOutput (cfgOptions config)
      transport = case optTransport (cfgOptions config) of
                    WsTransport      -> "ws"
                    BrowserTransport -> "browser"
      Backend bkName = cfgBackend config
      lt = Lock.LockTarget
             { Lock.ltBackend         = bkName
             , Lock.ltIrHash          = irHash
             , Lock.ltTransport       = transport
             , Lock.ltFiles           = coFileHashes codegenOutput
             , Lock.ltSharedTransport = Nothing
             }
  lock <- fromMaybe Lock.emptySynapseLock <$> Lock.readSynapseLock
  now  <- getCurrentTime
  Lock.writeSynapseLock $ lock
    { Lock.slTargets    = Map.insert (T.pack outputDir) lt (Lock.slTargets lock)
    , Lock.slUpdatedAt  = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
    , Lock.slHubCodegen = hubCodegenVer
    }

  logDebug debug "  Cache manifests written"

-- | Read the cached file hashes for three-way merge.
-- synapse.lock (project-level, committed to git) takes priority over ~/.cache.
getCachedFileHashes :: Config -> IO (Map.Map Text Text)
getCachedFileHashes config = do
  let outputDir = optOutput (cfgOptions config)
  lockResult <- Lock.readSynapseLock
  case lockResult >>= Lock.lookupLockTarget outputDir of
    Just lt -> pure (Lock.ltFiles lt)
    Nothing -> do
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
-- Config-file build
-- ============================================================================

-- | Run a build pass for every target in a SynapseConfig.
-- CLI options override per-target transport/outputDir only when explicitly
-- different from their defaults; targets own those fields.
-- Providers (no sharedTransport) are built first, then consumers (with sharedTransport)
-- get shim files that re-export from the provider's output.
-- Returns one result per target (name, outcome).
runBuildFromConfig
  :: SynapseConfig
  -> Options       -- ^ CLI flags (--debug, --force, --no-install, etc.)
  -> ToolLocations
  -> IO [(T.Text, Either SynapseCCError CompiledPath)]
runBuildFromConfig sc opts tools = do
  let allTargets  = Map.toList (scTargets sc)
      -- Partition: providers first (no sharedTransport), then consumers
      (providers, consumers) = foldr partitionTarget ([], []) allTargets
      partitionTarget (name, tc) (ps, cs) =
        case tcSharedTransport tc of
          Nothing -> ((name, tc) : ps, cs)
          Just _  -> (ps, (name, tc) : cs)

  -- Build providers first
  providerResults <- mapM buildTarget providers

  -- Build consumers: run hub-codegen for plugins only, then write shim files
  consumerResults <- forM consumers $ \(name, tc) -> do
    let config = buildConfigFromTarget opts sc tc
    logInfo $ "Building \"" <> name <> "\" → " <> T.pack (optOutput (cfgOptions config))
    logDebug (optDebug opts) $ "  target \"" <> name <> "\" uses sharedTransport"
    -- Run normal pipeline for plugins (generate list should be ["plugins"])
    result <- runPipeline config tools
    -- Write re-export shim files and update lock
    case (result, tcSharedTransport tc) of
      (Right _, Just providerName) ->
        case Map.lookup providerName (scTargets sc) of
          Just providerTc -> do
            let shimFiles = generateShimFiles (tcOutputDir tc) (tcOutputDir providerTc)
            createDirectoryIfMissing True (tcOutputDir tc)
            forM_ (Map.toList shimFiles) $ \(fileName, content) -> do
              let filePath = tcOutputDir tc </> T.unpack fileName
              TIO.writeFile filePath content
              logDebug (optDebug opts) $ "  Wrote shim: " <> T.pack filePath
            -- Update lock file with shim file hashes
            lock <- fromMaybe Lock.emptySynapseLock <$> Lock.readSynapseLock
            let outputKey = T.pack (tcOutputDir tc)
            case Map.lookup outputKey (Lock.slTargets lock) of
              Just lt -> do
                let shimHashes = Map.mapWithKey (\_ content -> Merge.computeFileHash content) shimFiles
                    updatedLt = lt
                      { Lock.ltSharedTransport = Just providerName
                      , Lock.ltFiles = Map.union shimHashes (Lock.ltFiles lt)
                      }
                Lock.writeSynapseLock $ lock
                  { Lock.slTargets = Map.insert outputKey updatedLt (Lock.slTargets lock) }
              Nothing -> pure ()
            logSuccess $ "Shim files written for \"" <> name <> "\""
          Nothing -> pure ()  -- Should not happen (validated in Config.hs)
      _ -> pure ()
    pure (name, result)

  pure $ providerResults ++ consumerResults
  where
    buildTarget (name, tc) = do
      let config = buildConfigFromTarget opts sc tc
      logInfo $ "Building \"" <> name <> "\" → " <> T.pack (optOutput (cfgOptions config))
      logDebug (optDebug opts) $ "  target \"" <> name <> "\" is defined in synapse.config.json under .targets"
      result <- if tcGenerate tc == ["transport"]
                   then runTransportOnlyPipeline config tools
                   else runPipeline config tools
      pure (name, result)

-- | Generate re-export shim files for a child target that shares transport
-- with a parent target. Computes the relative path from child → parent
-- and returns a map of filename → shim content.
generateShimFiles :: FilePath -> FilePath -> Map.Map Text Text
generateShimFiles childDir parentDir =
  let relPath = computeRelativePath childDir parentDir
      shimContent file = "export * from '" <> relPath <> "/" <> file <> "';\n"
  in Map.fromList
    [ ("transport.ts", shimContent "transport")
    , ("rpc.ts",       shimContent "rpc")
    , ("types.ts",     shimContent "types")
    ]

-- | Compute the relative path from childDir to parentDir.
-- E.g., "generated/substrate" → "generated" yields ".."
-- E.g., "src/gen/sub" → "src/gen" yields ".."
-- E.g., "generated-sub" → "generated" yields "../generated"
computeRelativePath :: FilePath -> FilePath -> Text
computeRelativePath childDir parentDir =
  let -- splitPath keeps trailing '/' on components; strip for comparison
      normalize = map (filter (/= '/'))
      childParts  = normalize (splitPath childDir)
      parentParts = normalize (splitPath parentDir)
      -- Find common prefix length
      commonLen   = length $ takeWhile id $ zipWith (==) childParts parentParts
      -- Steps up from child to common ancestor
      stepsUp     = length childParts - commonLen
      -- Steps down from common ancestor to parent
      stepsDown   = drop commonLen parentParts
      upParts     = replicate stepsUp ".."
      relParts    = upParts ++ stepsDown
      rel = T.intercalate "/" $ map T.pack relParts
  in if T.null rel then "." else rel

-- ============================================================================
-- Transport-Only Pipeline (no backend connection required)
-- ============================================================================

-- | Run the transport-only pipeline.
-- transport.ts is a static template parameterised only by --transport mode,
-- so no backend connection or IR generation is needed.
runTransportOnlyPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runTransportOnlyPipeline config tools = do
  let opts      = cfgOptions config
      debug     = optDebug opts
      outputDir = optOutput opts

  createDirectoryIfMissing True outputDir

  logStep "Generating transport layer..."
  codeResult <- generateTransportCode config tools
  case codeResult of
    Left err -> pure $ Left err
    Right out -> do
      logSuccess "Transport generated"
      -- Three-way merge (transport.ts is static — merge handles unchanged correctly
      -- even without a cache entry: if content matches what's on disk, skip write).
      cachedHashes <- if optForce opts then pure Map.empty else getCachedFileHashes config
      mergeResult  <- Merge.applyMerge (coFiles out) (coFileHashes out) cachedHashes outputDir
      let skipped = Merge.mrSkipped mergeResult
      unless (null skipped) $
        logInfo $ "  ⚠  " <> T.pack (show (length skipped))
                <> " file(s) skipped (user modifications preserved)"
      logDebug debug "  No backend, deps, build, or tests for transport-only target"
      pure $ Right $ CompiledPath outputDir

-- | Call hub-codegen --generate transport (no IR argument needed).
generateTransportCode :: Config -> ToolLocations -> IO (Either SynapseCCError CodegenOutput)
generateTransportCode config tools = do
  let debug          = optDebug (cfgOptions config)
      hubCodegenPath = toolPathToFilePath (toolHubCodegen tools)
      opts           = cfgOptions config
      targetArg      = T.unpack (targetToText (cfgTarget config))
      args =
        [ "--target",        targetArg
        , "--output-format", "json"
        , "--generate",      "transport"
        , "--transport",     case optTransport opts of
                               WsTransport      -> "ws"
                               BrowserTransport -> "browser"
        ]
  result <- runProcess hubCodegenPath args Nothing debug
  case prExitCode result of
    ExitSuccess ->
      case eitherDecodeStrict (TE.encodeUtf8 (prStdout result)) of
        Left parseErr -> pure $ Left $ HubCodegenError (T.pack parseErr) 0
        Right out     -> pure $ Right out
    ExitFailure code ->
      pure $ Left $ HubCodegenError (prStderr result) code

-- ============================================================================
-- IR Generation
-- ============================================================================

-- | Generate IR using plexus-synapse library (replaces subprocess call)
generateIR :: Config -> ToolLocations -> IO (Either SynapseCCError IRPath)
generateIR config _tools = do
  let debug  = optDebug (cfgOptions config)
      Backend bkName = cfgBackend config
      outputDir = optOutput (cfgOptions config)
      opts = cfgOptions config
      regHost = cfgHost config
      regPort = read (T.unpack (cfgPort config)) :: Int
      generatorInfo = ["synapse-cc:" <> synapseCCVersion]

  -- SAFE-3: resolve backend host:port via the registry.
  -- The registry's location is taken from --host/--port (defaults: 127.0.0.1:4444).
  resolution <- Registry.resolveBackendAddress regHost regPort bkName
  hpResult <- case resolution of
    Registry.ResolvedFromRegistry h p -> do
      logDebug debug $ "  Registry resolved " <> bkName <> " -> " <> h <> ":" <> T.pack (show p)
      pure $ Right (h, p)
    Registry.ResolvedFallback h p -> do
      logDebug debug $ "  Registry unreachable; using provided address " <> h <> ":" <> T.pack (show p)
      pure $ Right (h, p)
    Registry.NotInRegistry known ->
      pure $ Left $ BackendUnreachable bkName $
        "Backend '" <> bkName <> "' not in registry. Known: "
        <> (if null known then "<none>" else T.intercalate ", " known)
        <> ". Hint: run 'synapse-cc init' to scaffold a synapse.config.json"
  case hpResult of
    Left e -> pure (Left e)
    Right (host, port) -> do
      -- Compute IR file path in the cache directory:
      --   <cacheDir>/synapse/ir/<backend>/ir.json
      cacheDir <- getCacheDir opts
      let irDir  = cacheDir </> "synapse" </> "ir" </> T.unpack bkName
          irFile = irDir </> "ir.json"

      -- Ensure output and IR cache directories exist
      createDirectoryIfMissing True outputDir
      createDirectoryIfMissing True irDir

      -- Call plexus-synapse library directly (no subprocess).
      -- Pass [] as path: the backend is encoded in the env; [] = walk from root.
      logDebug debug $ "  Connecting to " <> host <> ":" <> T.pack (show port)
      logger <- Log.makeLogger Katip.ErrorS
      -- SAFE-2: resolve JWT token from --token / SYNAPSE_TOKEN / --token-file / ~/.plexus/tokens/<backend>
      token <- Auth.resolveToken opts bkName
      env <- initEnv host port bkName logger token
      -- Wrap in try to catch hard exceptions from child-plugin fetch errors
      rawResult <- try (runSynapseM env (buildIR generatorInfo []))
      result <- case rawResult of
        Left (ex :: SomeException) ->
          let raw = T.pack (show ex)
              msg = if "Connection refused" `T.isInfixOf` raw || "does not exist" `T.isInfixOf` raw
                      then "Cannot connect to backend — is it running?"
                      else T.takeWhile (/= '\n') raw
          in pure $ Left msg
        Right (Left synapseErr)    -> pure $ Left $ formatSynapseError synapseErr
        Right (Right ir)           -> pure $ Right ir

      case result of
        Left msg -> do
          logDebug debug $ "  Synapse error: " <> msg
          pure $ Left $ SynapseError msg 1

        Right ir -> do
          -- Encode IR to JSON and write to cache path
          let irBytes = BL.toStrict (Aeson.encode ir)
          BS.writeFile irFile irBytes

          -- Validate by round-tripping (ensures we can parse what we wrote)
          case eitherDecodeStrict irBytes of
            Left parseErr -> pure $ Left $ InvalidIR $ T.pack parseErr
            Right (_ :: IRData) -> pure $ Right $ IRPath irFile

-- | Format a SynapseError (from plexus-synapse) for display
formatSynapseError :: SynapseError -> Text
formatSynapseError err = case err of
  NavError ne ->
    let raw = T.pack (show ne)
    in if "Connection refused" `T.isInfixOf` raw || "does not exist" `T.isInfixOf` raw
         then "Cannot connect to backend — is it running?"
         else "Connection error: " <> T.takeWhile (/= '\n') raw
  TransportError t  -> t
  TransportErrorContext ctx ->
    "Cannot connect to " <> T.pack (show ctx)
  ParseError t      -> "Parse error: " <> t
  ValidationError t -> "Validation error: " <> t
  BackendError bt _ -> "Backend error: " <> T.pack (show bt)

-- | IR structure for reading plugin hashes
-- We only need the fields relevant for caching
data IRData = IRData
  { irdVersion      :: !Text
  , irdIrHash       :: !(Maybe Text)   -- ^ Content-stable hash of schema (no timestamps)
  , irdPlugins      :: !(Map.Map Text [Text])
  , irdPluginHashes :: !(Maybe (Map.Map Text PluginHashInfo))
  } deriving stock (Show, Generic)

instance FromJSON IRData where
  parseJSON = Aeson.withObject "IRData" $ \o -> IRData
    <$> o Aeson..: "irVersion"
    <*> o Aeson..:? "irHash"
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

-- | Generate code using hub-codegen, returning parsed JSON output.
-- Pass @Just namespaces@ to restrict generation to specific plugin namespaces
-- (equivalent to @--generate plugins --plugins ns1,ns2@).
-- Pass @Nothing@ for a full generation pass.
generateCode :: Config -> ToolLocations -> IRPath -> Maybe [Text] -> IO (Either SynapseCCError CodegenOutput)
generateCode config tools irPath nsFilter = do
  let debug          = optDebug (cfgOptions config)
      hubCodegenPath = toolPathToFilePath (toolHubCodegen tools)
      opts           = cfgOptions config
      target         = cfgTarget config
      targetArg      = T.unpack (targetToText target)
      backendUrl     = "ws://" <> T.unpack (cfgHost config) <> ":" <> T.unpack (cfgPort config)
      -- nsFilter: incremental mode (--generate plugins --plugins ...)
      filterArgs = case nsFilter of
        Nothing  -> []
        Just nss -> ["--generate", "plugins", "--plugins", T.unpack (T.intercalate "," nss)]
      -- cfgPlugins: full generation with plugin filtering (--plugins ... only, no --generate plugins)
      pluginFilterArgs = case cfgPlugins config of
        Just ps | null filterArgs -> ["--plugins", T.unpack (T.intercalate "," ps)]
        _                         -> []
      args =
        [ "--target",           targetArg
        , "--output-format",    "json"
        , "--transport", case optTransport opts of
            WsTransport      -> "ws"
            BrowserTransport -> "browser"
        , "--backend-url",      backendUrl
        ]
        ++ filterArgs
        ++ pluginFilterArgs
        ++ [ unIRPath irPath ]

  result <- runProcess hubCodegenPath args Nothing debug

  case prExitCode result of
    ExitSuccess -> do
      let stdoutBytes = TE.encodeUtf8 (prStdout result)
      case eitherDecodeStrict stdoutBytes of
        Left parseErr -> pure $ Left $ HubCodegenError (T.pack parseErr) 0
        Right out     -> pure $ Right out
    ExitFailure code ->
      pure $ Left $ HubCodegenError (prStderr result) code
