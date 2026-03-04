module Main where

import Control.Monad (when)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)
import System.IO (stdout, stderr, hSetEncoding, utf8)

import SynapseCC.CLI
import SynapseCC.Discover
import SynapseCC.Logging
import SynapseCC.Pipeline
import SynapseCC.Types

-- ============================================================================
-- Main Entry Point
-- ============================================================================

main :: IO ()
main = do
  -- Set UTF-8 encoding for stdout/stderr to handle Unicode characters
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8

  -- Parse command-line arguments
  config <- parseArgs

  let debug = optDebug (cfgOptions config)

  -- Print version
  when debug $ TIO.putStrLn versionInfo

  -- Discover tools
  logStep "Discovering tools..."
  toolsResult <- discoverTools (cfgOptions config)
  case toolsResult of
    Left err -> do
      TIO.putStrLn $ formatError err
      exitFailure

    Right tools -> do
      logSuccess "Found all required tools"

      -- Connect to backend
      logStep $ "Connecting to " <> backendName (cfgBackend config) <> " via registry at " <> cfgHost config <> ":" <> cfgPort config <> "..."

      -- Run the pipeline
      pipelineResult <- runPipeline config tools
      case pipelineResult of
        Left err -> do
          TIO.putStrLn $ formatError err
          exitFailure

        Right (CompiledPath outputPath) -> do
          TIO.putStrLn ""
          logSuccess $ "Client ready at " <> T.pack outputPath
          exitSuccess

