module Main where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

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
  -- Parse command-line arguments
  config <- parseArgs

  let debug = optDebug (cfgOptions config)

  -- Print version
  when debug $ TIO.putStrLn versionInfo

  -- Discover tools
  logStep "Discovering tools..."
  toolsResult <- discoverTools debug
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

-- ============================================================================
-- Helpers
-- ============================================================================

when :: Applicative f => Bool -> f () -> f ()
when True action = action
when False _ = pure ()
