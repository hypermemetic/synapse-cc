-- | Subprocess execution helpers
module SynapseCC.Process
  ( runProcess
  , runProcessWithInput
  , ProcessResult(..)
  ) where

import Control.Monad (unless, when)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import System.Exit (ExitCode(..))
import System.IO (Handle, hClose, hGetContents, hPutStr)
import System.Process hiding (runProcess)

import SynapseCC.Logging (logDebug)

-- ============================================================================
-- Process Execution
-- ============================================================================

-- | Result of running a process
data ProcessResult = ProcessResult
  { prExitCode :: !ExitCode
  , prStdout   :: !Text
  , prStderr   :: !Text
  } deriving (Show, Eq)

-- | Run a process and capture output
runProcess
  :: FilePath      -- ^ Executable path
  -> [String]      -- ^ Arguments
  -> Maybe FilePath -- ^ Working directory (Nothing = current)
  -> Bool          -- ^ Debug mode
  -> IO ProcessResult
runProcess exe args mbCwd debug = do
  logDebug debug $ "Running: " <> T.pack exe <> " " <> T.pack (unwords args)
  case mbCwd of
    Just cwd -> logDebug debug $ "  Working directory: " <> T.pack cwd
    Nothing  -> pure ()

  (exitCode, stdout, stderr) <- readProcessWithExitCode' exe args mbCwd ""

  logProcessOutput debug stdout stderr
  pure $ ProcessResult exitCode stdout stderr

-- | Run a process with stdin input
runProcessWithInput
  :: FilePath      -- ^ Executable path
  -> [String]      -- ^ Arguments
  -> Maybe FilePath -- ^ Working directory (Nothing = current)
  -> Text          -- ^ Stdin input
  -> Bool          -- ^ Debug mode
  -> IO ProcessResult
runProcessWithInput exe args mbCwd input debug = do
  logDebug debug $ "Running: " <> T.pack exe <> " " <> T.pack (unwords args)
  case mbCwd of
    Just cwd -> logDebug debug $ "  Working directory: " <> T.pack cwd
    Nothing  -> pure ()
  logDebug debug $ "  With input: " <> T.take 100 input <> "..."

  (exitCode, stdout, stderr) <- readProcessWithExitCode' exe args mbCwd (T.unpack input)

  logProcessOutput debug stdout stderr
  pure $ ProcessResult exitCode stdout stderr

-- ============================================================================
-- Helpers
-- ============================================================================

-- | Log process stdout/stderr when in debug mode.
logProcessOutput :: Bool -> Text -> Text -> IO ()
logProcessOutput debug stdout stderr = when debug $ do
  unless (T.null stdout) $ do
    let len = T.length stdout
    if len > 5000
      then logDebug debug $ "  Stdout: <large output, " <> T.pack (show len) <> " chars, truncated>"
      else do
        logDebug debug "  Stdout:"
        logDebug debug $ "    " <> stdout
  unless (T.null stderr) $ do
    logDebug debug "  Stderr:"
    logDebug debug $ "    " <> stderr

-- | Like readProcessWithExitCode but with working directory support
readProcessWithExitCode'
  :: FilePath
  -> [String]
  -> Maybe FilePath
  -> String
  -> IO (ExitCode, Text, Text)
readProcessWithExitCode' exe args mbCwd input = do
  let process = (proc exe args)
        { cwd = mbCwd
        , std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        }

  (Just stdin, Just stdout, Just stderr, ph) <- createProcess process

  -- Write input and close stdin
  hPutStr stdin input
  hClose stdin

  -- Read output strictly as ByteString first, then decode with lenient error handling
  stdoutBytes <- BS.hGetContents stdout
  stderrBytes <- BS.hGetContents stderr

  let stdoutText = TE.decodeUtf8With TE.lenientDecode stdoutBytes
      stderrText = TE.decodeUtf8With TE.lenientDecode stderrBytes

  -- Wait for process to complete
  exitCode <- waitForProcess ph

  pure (exitCode, stdoutText, stderrText)
