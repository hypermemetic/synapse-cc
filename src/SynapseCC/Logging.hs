-- | Pretty logging and progress indicators
module SynapseCC.Logging
  ( logInfo
  , logSuccess
  , logError
  , logDebug
  , logStep
  ) where

import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.Console.ANSI

-- ============================================================================
-- Logging
-- ============================================================================

-- | Log an info message
logInfo :: Text -> IO ()
logInfo msg = do
  setSGR [SetColor Foreground Vivid Blue]
  TIO.putStr "[i] "
  setSGR [Reset]
  TIO.putStrLn msg

-- | Log a success message
logSuccess :: Text -> IO ()
logSuccess msg = do
  setSGR [SetColor Foreground Vivid Green]
  TIO.putStr "[+] "
  setSGR [Reset]
  TIO.putStrLn msg

-- | Log an error message
logError :: Text -> IO ()
logError msg = do
  setSGR [SetColor Foreground Vivid Red]
  TIO.putStr "[!] "
  setSGR [Reset]
  TIO.putStrLn msg

-- | Log a debug message (only if debug mode enabled)
logDebug :: Bool -> Text -> IO ()
logDebug True msg = do
  setSGR [SetColor Foreground Vivid Cyan, SetConsoleIntensity FaintIntensity]
  TIO.putStr "[debug] "
  TIO.putStrLn msg
  setSGR [Reset]
logDebug False _ = pure ()

-- | Log a pipeline step
logStep :: Text -> IO ()
logStep msg = do
  TIO.putStrLn ""
  setSGR [SetColor Foreground Vivid Yellow, SetConsoleIntensity BoldIntensity]
  TIO.putStr "==> "
  TIO.putStrLn msg
  setSGR [Reset]
