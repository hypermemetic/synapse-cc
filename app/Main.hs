module Main where

import Control.Monad (when, forM_)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)
import System.IO (stdout, stderr, hSetEncoding, hSetBuffering, utf8, BufferMode(..))

import SynapseCC.CLI
import SynapseCC.Config (initSynapseConfig, loadSynapseConfig, synapseConfigPath)
import SynapseCC.Discover
import SynapseCC.Logging
import SynapseCC.Pipeline
import SynapseCC.Types
import SynapseCC.Watch (runWatch)

-- ============================================================================
-- Main Entry Point
-- ============================================================================

main :: IO ()
main = do
  -- Set UTF-8 encoding for stdout/stderr to handle Unicode characters
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering

  cmd <- parseCommand

  case cmd of
    -- ------------------------------------------------------------------
    -- synapse-cc init
    -- ------------------------------------------------------------------
    CmdInit -> do
      result <- initSynapseConfig synapseConfigPath
      case result of
        Left err -> do
          TIO.putStrLn $ "[!] " <> err
          exitFailure
        Right () -> do
          logSuccess $ "Created " <> T.pack synapseConfigPath
          TIO.putStrLn "Edit it to configure your targets, then run:"
          TIO.putStrLn "  synapse-cc build"
          exitSuccess

    -- ------------------------------------------------------------------
    -- synapse-cc build <target> <backend> [opts]
    -- ------------------------------------------------------------------
    CmdBuild config -> do
      let debug = optDebug (cfgOptions config)
      when debug $ TIO.putStrLn versionInfo

      logStep "Discovering tools..."
      toolsResult <- discoverTools (cfgOptions config)
      case toolsResult of
        Left err -> do
          TIO.putStrLn $ formatError err
          exitFailure

        Right tools -> do
          logSuccess "Found all required tools"
          logStep $ "Connecting to " <> backendName (cfgBackend config)
                 <> " at ws://" <> cfgHost config <> ":" <> cfgPort config <> "..."

          pipelineResult <- runPipeline config tools
          case pipelineResult of
            Left err -> do
              TIO.putStrLn $ formatError err
              exitFailure

            Right (CompiledPath outputPath) -> do
              TIO.putStrLn ""
              logSuccess $ "Client → " <> T.pack outputPath <> "/"
              exitSuccess

    -- ------------------------------------------------------------------
    -- synapse-cc build   (reads synapse.config.json, all targets)
    -- ------------------------------------------------------------------
    CmdBuildFromConfig opts -> do
      let debug = optDebug opts
      when debug $ TIO.putStrLn versionInfo

      cfgResult <- loadSynapseConfig
      case cfgResult of
        Left err -> do
          TIO.putStrLn $ "[!] " <> err
          TIO.putStrLn "Hint: run 'synapse-cc init' to create synapse.config.json"
          TIO.putStrLn "      or provide target/backend: synapse-cc build typescript substrate"
          exitFailure

        Right sc -> do
          logStep "Discovering tools..."
          toolsResult <- discoverTools opts
          case toolsResult of
            Left err -> do
              TIO.putStrLn $ formatError err
              exitFailure

            Right tools -> do
              logSuccess "Found all required tools"
              results <- runBuildFromConfig sc opts tools
              forM_ results $ \(targetName, result) ->
                case result of
                  Left err                     ->
                    TIO.putStrLn $ "[!] " <> targetName <> ": " <> formatError err
                  Right (CompiledPath outPath) ->
                    logSuccess $ targetName <> " → " <> T.pack outPath <> "/"
              if all (either (const False) (const True) . snd) results
                then exitSuccess
                else exitFailure

    -- ------------------------------------------------------------------
    -- synapse-cc watch <backend> [plugins...] [--target name]
    -- ------------------------------------------------------------------
    CmdWatch watchArgs -> do
      let debug = optDebug (waOptions watchArgs)
      when debug $ TIO.putStrLn versionInfo

      logStep "Discovering tools..."
      toolsResult <- discoverTools (waOptions watchArgs)
      case toolsResult of
        Left err -> do
          TIO.putStrLn $ formatError err
          exitFailure

        Right tools -> do
          logSuccess "Found all required tools"
          runWatch watchArgs tools
