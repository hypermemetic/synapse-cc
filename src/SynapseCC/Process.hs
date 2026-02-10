-- | Subprocess execution helpers
module SynapseCC.Process
  ( runProcess
  , runProcessWithInput
  , ProcessResult(..)
  ) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import qualified Data.Text.IO as TIO
import System.Exit (ExitCode(..))
import System.IO (Handle, hClose, hGetContents, hPutStr)
import System.Process hiding (runProcess)

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
  when debug $ do
    putStrLn $ "Running: " ++ exe ++ " " ++ unwords args
    case mbCwd of
      Just cwd -> putStrLn $ "  Working directory: " ++ cwd
      Nothing -> pure ()

  (exitCode, stdout, stderr) <- readProcessWithExitCode' exe args mbCwd ""

  when debug $ do
    unless (T.null stdout) $ do
      let len = T.length stdout
      if len > 1000
        then putStrLn $ "  Stdout: <large output, " ++ show len ++ " chars, truncated>"
        else do
          putStrLn "  Stdout:"
          putStrLn $ "    " ++ T.unpack stdout
    unless (T.null stderr) $ do
      putStrLn "  Stderr:"
      putStrLn $ "    " ++ T.unpack stderr

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
  when debug $ do
    putStrLn $ "Running: " ++ exe ++ " " ++ unwords args
    case mbCwd of
      Just cwd -> putStrLn $ "  Working directory: " ++ cwd
      Nothing -> pure ()
    putStrLn $ "  With input: " ++ T.unpack (T.take 100 input) ++ "..."

  (exitCode, stdout, stderr) <- readProcessWithExitCode' exe args mbCwd (T.unpack input)

  when debug $ do
    unless (T.null stdout) $ do
      let len = T.length stdout
      if len > 1000
        then putStrLn $ "  Stdout: <large output, " ++ show len ++ " chars, truncated>"
        else do
          putStrLn "  Stdout:"
          putStrLn $ "    " ++ T.unpack stdout
    unless (T.null stderr) $ do
      putStrLn "  Stderr:"
      putStrLn $ "    " ++ T.unpack stderr

  pure $ ProcessResult exitCode stdout stderr

-- ============================================================================
-- Helpers
-- ============================================================================

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

when :: Applicative f => Bool -> f () -> f ()
when True action = action
when False _ = pure ()

unless :: Applicative f => Bool -> f () -> f ()
unless False action = action
unless True _ = pure ()
