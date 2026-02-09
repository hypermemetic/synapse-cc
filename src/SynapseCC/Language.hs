-- | Language-specific integrations (dependency install, build, etc.)
module SynapseCC.Language
  ( installDependencies
  , buildProject
  , runTests
  ) where

import Control.Monad (when)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode(..))

import SynapseCC.Types
import SynapseCC.Process

-- ============================================================================
-- Language Integration (Phase 2 - Partially implemented)
-- ============================================================================

-- | Install dependencies for generated code
installDependencies :: Target -> GeneratedPath -> Bool -> IO (Either SynapseCCError ())
installDependencies _ _ _ = pure $ Right ()  -- TODO: Implement in Phase 2

-- | Build/compile generated code
buildProject :: Target -> GeneratedPath -> Bool -> IO (Either SynapseCCError CompiledPath)
buildProject _ genPath _ = pure $ Right $ CompiledPath $ unGeneratedPath genPath  -- TODO: Implement in Phase 2

-- | Run smoke tests for generated code
runTests :: Target -> GeneratedPath -> Bool -> IO (Either SynapseCCError ())
runTests target genPath debug = case target of
  TypeScript -> runTypeScriptTests genPath debug
  Python -> pure $ Right ()  -- TODO: Implement Python tests
  Rust -> pure $ Right ()  -- TODO: Implement Rust tests

-- | Run TypeScript smoke tests using npm
runTypeScriptTests :: GeneratedPath -> Bool -> IO (Either SynapseCCError ())
runTypeScriptTests (GeneratedPath path) debug = do
  when debug $ putStrLn $ "[*] Running smoke tests in " ++ path

  -- Check if npm is available
  result <- runProcess "npm" ["test"] (Just path) debug

  case prExitCode result of
    ExitSuccess -> do
      when debug $ putStrLn "  [+] Tests passed"
      pure $ Right ()
    ExitFailure code -> do
      let stderr = prStderr result
      pure $ Left $ LanguageToolError "npm test" stderr code
