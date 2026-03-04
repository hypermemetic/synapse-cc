-- | Language-specific integrations (dependency install, build, etc.)
module SynapseCC.Language
  ( installDependencies
  , buildProject
  , runTests
  ) where

import Control.Monad (when)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, findExecutable)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))

import SynapseCC.Types
import SynapseCC.Process

-- ============================================================================
-- Language Integration (Phase 2)
-- ============================================================================

-- | Supported package managers for TypeScript
data PackageManager
  = Npm
  | Pnpm
  | Yarn
  | Bun
  deriving (Show, Eq)

-- | Get install command name for package manager
packageManagerCommand :: PackageManager -> String
packageManagerCommand = \case
  Npm  -> "npm"
  Pnpm -> "pnpm"
  Yarn -> "yarn"
  Bun  -> "bun"

-- | Get (command, args-prefix) for running an exec via the package manager
-- e.g. bun x tsc, pnpm exec tsc, npx tsc
packageManagerExec :: PackageManager -> (String, [String])
packageManagerExec = \case
  Bun  -> ("bun", ["x"])
  Pnpm -> ("pnpm", ["exec"])
  Yarn -> ("yarn", [])
  Npm  -> ("npx", [])

-- | Get (command, args) for running tests via the package manager
packageManagerTestCmd :: PackageManager -> (String, [String])
packageManagerTestCmd = \case
  Bun  -> ("bun", ["test"])
  Pnpm -> ("pnpm", ["test"])
  Yarn -> ("yarn", ["test"])
  Npm  -> ("npm", ["test"])

-- | Detect which package manager to use for TypeScript project
detectPackageManager :: GeneratedPath -> Bool -> IO PackageManager
detectPackageManager (GeneratedPath path) debug = do
  when debug $ putStrLn "[*] Detecting package manager..."

  -- Priority 1: Check for lockfiles
  hasPnpmLock <- doesFileExist (path </> "pnpm-lock.yaml")
  if hasPnpmLock
    then do
      when debug $ putStrLn "  [+] Found pnpm-lock.yaml, using pnpm"
      pure Pnpm
    else do
      hasYarnLock <- doesFileExist (path </> "yarn.lock")
      if hasYarnLock
        then do
          when debug $ putStrLn "  [+] Found yarn.lock, using yarn"
          pure Yarn
        else do
          -- Priority 2: Check available commands (prefer pnpm > yarn > bun > npm)
          hasPnpm <- isJust <$> findExecutable "pnpm"
          if hasPnpm
            then do
              when debug $ putStrLn "  [+] pnpm available, using pnpm"
              pure Pnpm
            else do
              hasYarn <- isJust <$> findExecutable "yarn"
              if hasYarn
                then do
                  when debug $ putStrLn "  [+] yarn available, using yarn"
                  pure Yarn
                else do
                  hasBun <- isJust <$> findExecutable "bun"
                  if hasBun
                    then do
                      when debug $ putStrLn "  [+] bun available, using bun"
                      pure Bun
                    else do
                      when debug $ putStrLn "  [+] Defaulting to bun"
                      pure Bun

-- | Check if package.json contains workspace protocol
checkForWorkspaceProtocol :: GeneratedPath -> IO Bool
checkForWorkspaceProtocol (GeneratedPath path) = do
  let packageJson = path </> "package.json"
  exists <- doesFileExist packageJson
  if exists
    then do
      content <- TIO.readFile packageJson
      pure $ "workspace:" `T.isInfixOf` content
    else pure False

-- | Provide helpful suggestions based on error patterns
checkInstallError :: Text -> [Text]
checkInstallError stderr
  | "EACCES" `T.isInfixOf` stderr =
      ["Permission denied - try: sudo chown -R $USER ~/.npm"]
  | "ENOTFOUND" `T.isInfixOf` stderr =
      ["Network error - check your internet connection"]
  | "ENETUNREACH" `T.isInfixOf` stderr =
      ["Network unreachable - check firewall/proxy settings"]
  | "workspace:" `T.isInfixOf` stderr =
      ["npm doesn't support workspace: protocol"
      ,"Use pnpm, yarn, or bun: npm install -g pnpm && pnpm install"
      ,"Or enable bundle-transport: --bundle-transport=true"]
  | otherwise = []

-- ============================================================================
-- Dependency Installation
-- ============================================================================

-- | Install dependencies for generated code
installDependencies :: Target -> GeneratedPath -> Bool -> IO (Either SynapseCCError ())
installDependencies TypeScript genPath debug = do
  when debug $ putStrLn $ "[*] Installing dependencies in " ++ unGeneratedPath genPath

  -- Detect package manager
  pm <- detectPackageManager genPath debug
  let pmCmd = packageManagerCommand pm

  -- Check for workspace protocol with npm (warn user)
  when (pm == Npm) $ do
    hasWorkspace <- checkForWorkspaceProtocol genPath
    when hasWorkspace $ do
      putStrLn "\nWarning: This project uses the 'workspace:*' protocol"
      putStrLn "npm does not support workspace protocol."
      putStrLn "\nOptions:"
      putStrLn "  1. Use pnpm: npm install -g pnpm && pnpm install"
      putStrLn "  2. Use yarn: npm install -g yarn && yarn install"
      putStrLn "  3. Set --bundle-transport=true to avoid workspace dependency"

  -- Verify package manager is actually available
  mbPmPath <- findExecutable pmCmd
  case mbPmPath of
    Nothing -> pure $ Left $ ToolNotFound (T.pack pmCmd)
      [ "Install Node.js from https://nodejs.org"
      , "Or install " <> T.pack pmCmd <> " separately: npm install -g " <> T.pack pmCmd
      ]
    Just _ -> do
      -- Run install command
      result <- runProcess pmCmd ["install"] (Just $ unGeneratedPath genPath) debug

      case prExitCode result of
        ExitSuccess -> do
          when debug $ putStrLn "  [+] Dependencies installed"
          pure $ Right ()
        ExitFailure code -> do
          let suggestions = checkInstallError (prStderr result)
          pure $ Left $ LanguageToolError
            (T.pack $ pmCmd ++ " install")
            (if null suggestions
              then prStderr result
              else prStderr result <> "\n\nSuggestions:\n" <> T.unlines suggestions)
            code

installDependencies Python _ debug = do
  when debug $ putStrLn "[*] Python dependency installation not yet implemented (Phase 2 TODO)"
  pure $ Right ()

installDependencies Rust _ debug = do
  when debug $ putStrLn "[*] Rust dependency installation not yet implemented (Phase 2 TODO)"
  pure $ Right ()

-- ============================================================================
-- Building/Type-checking
-- ============================================================================

-- | Build/compile generated code
buildProject :: Target -> GeneratedPath -> Bool -> IO (Either SynapseCCError CompiledPath)
buildProject TypeScript genPath debug = do
  when debug $ putStrLn $ "[*] Type-checking TypeScript in " ++ unGeneratedPath genPath

  pm <- detectPackageManager genPath debug
  let (cmd, prefix) = packageManagerExec pm
      args = prefix ++ ["tsc", "--noEmit"]

  result <- runProcess cmd args (Just $ unGeneratedPath genPath) debug

  case prExitCode result of
    ExitSuccess -> do
      when debug $ putStrLn "  [+] TypeScript type-check passed"
      pure $ Right $ CompiledPath $ unGeneratedPath genPath
    ExitFailure code -> do
      pure $ Left $ LanguageToolError "tsc" (prStderr result) code

buildProject Python genPath debug = do
  when debug $ putStrLn "[*] Python build not yet implemented (Phase 2 TODO)"
  pure $ Right $ CompiledPath $ unGeneratedPath genPath

buildProject Rust genPath debug = do
  when debug $ putStrLn "[*] Rust build not yet implemented (Phase 2 TODO)"
  pure $ Right $ CompiledPath $ unGeneratedPath genPath

-- ============================================================================
-- Testing
-- ============================================================================

-- | Run smoke tests for generated code
runTests :: Target -> GeneratedPath -> Bool -> IO (Either SynapseCCError ())
runTests target genPath debug = case target of
  TypeScript -> runTypeScriptTests genPath debug
  Python -> pure $ Right ()  -- TODO: Implement Python tests
  Rust -> pure $ Right ()  -- TODO: Implement Rust tests

-- | Run TypeScript smoke tests
runTypeScriptTests :: GeneratedPath -> Bool -> IO (Either SynapseCCError ())
runTypeScriptTests genPath debug = do
  when debug $ putStrLn $ "[*] Running smoke tests in " ++ unGeneratedPath genPath

  pm <- detectPackageManager genPath debug
  let (cmd, args) = packageManagerTestCmd pm
      toolLabel = T.pack cmd <> " test"

  result <- runProcess cmd args (Just $ unGeneratedPath genPath) debug

  case prExitCode result of
    ExitSuccess -> do
      when debug $ putStrLn "  [+] Tests passed"
      pure $ Right ()
    ExitFailure code -> do
      pure $ Left $ LanguageToolError toolLabel (prStderr result) code
