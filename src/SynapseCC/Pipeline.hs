-- | Pipeline orchestration - running the full toolchain
module SynapseCC.Pipeline
  ( runPipeline
  , generateIR
  , generateCode
  ) where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON, eitherDecodeStrict)
import qualified Data.ByteString as BS
import Data.Monoid (mempty)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)

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
      when debug $ putStrLn "\n[+] Full cache hit (versions match)"
      when debug $ putStrLn "  [*] Using cached output"
      -- TODO: Copy cached code to output directory if needed
      let outputPath = optOutput (cfgOptions config)
      pure $ Right $ CompiledPath outputPath

    CacheMiss reason -> do
      when debug $ putStrLn $ "\n[!] Cache miss: " ++ show reason
      when debug $ putStrLn "  [*] Regenerating..."
      runFullPipeline config tools

    PartialCacheHit valid invalid -> do
      when debug $ putStrLn "\n[*] Partial cache hit"
      when debug $ putStrLn $ "  [+] Valid plugins: " ++ show valid
      when debug $ putStrLn $ "  [!] Invalid plugins: " ++ show invalid
      when debug $ putStrLn "  [*] Regenerating invalid plugins..."
      -- TODO: Implement partial regeneration
      -- For now, do full regeneration
      runFullPipeline config tools

-- | Run the full pipeline without cache
runFullPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runFullPipeline config tools = do
  let debug = optDebug (cfgOptions config)

  -- Step 1: Generate IR
  when debug $ putStrLn "\n[*] Generating IR..."
  irResult <- generateIR config tools
  case irResult of
    Left err -> pure $ Left err
    Right irPath -> do
      when debug $ putStrLn $ "  [+] IR generated at " ++ unIRPath irPath

      -- Step 2: Generate code
      when debug $ putStrLn "\n[*] Generating code..."
      codeResult <- generateCode config tools irPath
      case codeResult of
        Left err -> pure $ Left err
        Right genPath -> do
          when debug $ putStrLn $ "  [+] Code generated at " ++ unGeneratedPath genPath

          -- Step 3: Install dependencies (if enabled)
          installResult <- if optInstallDeps (cfgOptions config)
            then do
              when debug $ putStrLn "\n[*] Installing dependencies..."
              Language.installDependencies (cfgTarget config) genPath debug
            else do
              when debug $ putStrLn "\n[*] Skipping dependency installation (--no-install)"
              pure $ Right ()

          case installResult of
            Left err -> pure $ Left err
            Right () -> do

              -- Step 4: Build project (if enabled)
              buildResult <- if optBuild (cfgOptions config)
                then do
                  when debug $ putStrLn "\n[*] Building project..."
                  Language.buildProject (cfgTarget config) genPath debug
                else do
                  when debug $ putStrLn "\n[*] Skipping build (--no-build)"
                  pure $ Right $ CompiledPath $ unGeneratedPath genPath

              case buildResult of
                Left err -> pure $ Left err
                Right compiledPath -> do

                  -- Step 5: Run tests (if enabled)
                  if optRunTests (cfgOptions config)
                    then do
                      when debug $ putStrLn "\n[*] Running smoke tests..."
                      testResult <- Language.runTests (cfgTarget config) genPath debug
                      case testResult of
                        Left err -> pure $ Left err
                        Right () -> do
                          when debug $ putStrLn "  [+] All tests passed"
                          writeCache config compiledPath
                          pure $ Right compiledPath
                    else do
                      writeCache config compiledPath
                      pure $ Right compiledPath

-- | Write cache manifests after successful generation
writeCache :: Config -> CompiledPath -> IO ()
writeCache config _compiledPath = do
  let debug = optDebug (cfgOptions config)
  when debug $ putStrLn "\n[*] Writing cache manifests..."
  -- TODO: Implement cache writing with actual plugin hashes
  -- For now, write empty cache manifests to enable basic caching
  Cache.writeIRCacheManifest (cfgOptions config) (cfgBackend config) mempty
  Cache.writeCodeCacheManifest (cfgOptions config) (cfgBackend config) (cfgTarget config) mempty
  when debug $ putStrLn "  [+] Cache manifests written"

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

-- | Minimal IR structure for validation (we don't need the full structure)
data IRData = IRData
  { irVersion :: !Text
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
      opts = cfgOptions config

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

