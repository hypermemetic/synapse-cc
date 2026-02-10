-- | Pipeline orchestration - running the full toolchain
module SynapseCC.Pipeline
  ( runPipeline
  , generateIR
  , generateCode
  ) where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON, eitherDecodeStrict)
import qualified Data.ByteString as BS
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

-- ============================================================================
-- Pipeline Orchestration
-- ============================================================================

-- | Run the complete pipeline
runPipeline :: Config -> ToolLocations -> IO (Either SynapseCCError CompiledPath)
runPipeline config tools = do
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

          -- Step 3: Language-specific build (if enabled)
          compiledResult <- if optBuild (cfgOptions config)
            then do
              when debug $ putStrLn "\n[*] Building..."
              -- TODO: Implement language-specific build
              pure $ Right $ CompiledPath $ unGeneratedPath genPath
            else
              pure $ Right $ CompiledPath $ unGeneratedPath genPath

          case compiledResult of
            Left err -> pure $ Left err
            Right compiledPath -> do
              -- Step 4: Run tests (if enabled)
              if optRunTests (cfgOptions config)
                then do
                  when debug $ putStrLn "\n[*] Running smoke tests..."
                  testResult <- Language.runTests (cfgTarget config) genPath debug
                  case testResult of
                    Left err -> pure $ Left err
                    Right () -> do
                      when debug $ putStrLn "  [+] All tests passed"
                      pure $ Right compiledPath
                else
                  pure $ Right compiledPath

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

  -- Build synapse command: synapse -H <host> -P <port> -i <backend>
  let host = cfgHost config
      port = cfgPort config
      args = ["-H", T.unpack host, "-P", T.unpack port, "-i", T.unpack backendName]

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

