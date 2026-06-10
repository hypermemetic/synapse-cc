module Main where

import Control.Monad (when, forM_)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (ExitCode(..), exitFailure, exitSuccess, exitWith)
import System.IO (stdout, stderr, hSetEncoding, hSetBuffering, utf8, BufferMode(..))

import qualified Synapse.Self.Command as SelfCmd

import SynapseCC.CLI
import SynapseCC.Config (initSynapseConfig, InitResult(..), loadSynapseConfig, synapseConfigPath)
import SynapseCC.Detect (ProjectHint(..), defaultDetectors)
import SynapseCC.Discover
import SynapseCC.Logging
import SynapseCC.Pipeline
import SynapseCC.Types
import SynapseCC.Wait (runWait)
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
    CmdInit mBackend -> do
      -- Z2H-5: explicit backend wins; otherwise infer (co-located service
      -- crate, then local registry at 127.0.0.1:4444). Never a silent default.
      result <- initSynapseConfig synapseConfigPath defaultDetectors mBackend "127.0.0.1" 4444
      case result of
        Left err -> do
          TIO.putStrLn $ "[!] " <> err
          exitFailure
        Right initResult -> do
          logSuccess $ "Created " <> T.pack synapseConfigPath
                    <> " (backend: " <> irBackend initResult <> ")"
          -- If the backend was inferred (not given explicitly), SAY SO.
          case irBackendNote initResult of
            Just note -> logInfo note
            Nothing   -> pure ()
          -- If a detector gave a reason, surface it so the user knows
          -- why the generated config has a particular transport.
          case phReason (irHint initResult) of
            Just reason -> logInfo reason
            Nothing     -> pure ()
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
          logStep $ "Resolving " <> backendName (cfgBackend config)
                 <> " via registry at ws://" <> cfgHost config <> ":" <> cfgPort config <> "..."

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
                  Left err ->
                    -- formatError includes its own "[!] Error: " prefix — strip it
                    -- to avoid "[!] target: [!] Error: ..." doubling
                    let msg = T.strip (formatError err)
                        bare = maybe msg T.strip (T.stripPrefix "[!] Error:" msg
                                               >>= Just . T.stripStart)
                    in logError $ targetName <> ": " <> bare
                  Right (CompiledPath outPath) ->
                    logSuccess $ targetName <> " → " <> T.pack outPath <> "/"
              if all (either (const False) (const True) . snd) results
                then exitSuccess
                else exitFailure

    -- ------------------------------------------------------------------
    -- synapse-cc wait [--timeout N] [--interval MS]
    -- ------------------------------------------------------------------
    CmdWait waitArgs -> do
      ok <- runWait waitArgs
      if ok then exitSuccess else exitFailure

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

    -- ------------------------------------------------------------------
    -- synapse-cc _self <backend> <verb> ...   (SELF-6)
    -- ------------------------------------------------------------------
    -- Delegates straight to the shared handler that @synapse _self@ uses.
    -- Keeping the dispatch thin here (one line of real work) is the
    -- point of SELF-6: both CLIs must stay behavior-identical.
    CmdSelf selfCmd -> do
      code <- SelfCmd.runSelfCommand selfCmd
      case code of
        ExitSuccess     -> exitSuccess
        ExitFailure _   -> exitWith code
