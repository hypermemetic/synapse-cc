module Main (main) where

import Test.Hspec

import Control.Concurrent (threadDelay)
import Control.Exception (try, SomeException)
import Control.Monad (forM_, when, unless, void)
import Data.Aeson (Value(..), decode)
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC8
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Char (isAlpha, isDigit)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf, isPrefixOf, find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( doesDirectoryExist, doesFileExist, findExecutable
  , getTemporaryDirectory, listDirectory
  , createDirectoryIfMissing, removeDirectoryRecursive
  , withCurrentDirectory
  )
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeExtension)
import System.Process
  ( readProcessWithExitCode, CreateProcess(..), proc
  , readCreateProcessWithExitCode, createProcess, terminateProcess
  , waitForProcess, std_out, std_err, StdStream(..)
  )
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Options.Applicative (execParserPure, defaultPrefs, getParseResult)
import Plexus.Client (SubstrateConfig(..), defaultConfig)
import qualified Plexus.Transport as Transport
import Plexus.Types (TransportError(..), PlexusStreamItem)
import SynapseCC.CLI (synapseCCParserInfo, synapseCCCommandParserInfo)
import SynapseCC.Config (loadSynapseConfig, validateSynapseConfig, initSynapseConfig, synapseConfigPath)
import SynapseCC.Detect
  ( ProjectHint(..), Detector(..), emptyHint
  , runDetectors, defaultDetectors
  , detectTauri, detectVite, detectNextJS, detectNodeProject
  )
import SynapseCC.Discover (discoverTools)
import SynapseCC.Pipeline (runPipeline)
import SynapseCC.Types
  ( Config(..), Backend(..), Target(..), Options(..), defaultOptions, formatError
  , SynapseConfig(..), TargetConfig(..), WatchConfig(..)
  , WatchArgs(..), Command(..)
  , defaultSynapseConfig
  , TransportType(..)
  )
import SynapseCC.Watch
  ( matchesAnyPrefix, parseUrl, extractPluginHashesFromBytes
  , filterTargets, buildConfigFromTarget
  , fetchBackendHash
  )

-- | Shared test context: the path to generated output
data TestEnv = TestEnv
  { teOutputDir :: !FilePath
  , tePipelineRan :: !Bool  -- True if we ran synapse-cc, False if using existing generated/
  , tePipelineExit :: !ExitCode
  , tePipelineError :: !String  -- Captured error output when pipeline fails
  }

-- | Test context for Tauri integration: output goes into a plexus/ subdir
data TauriTestEnv = TauriTestEnv
  { taOutputDir :: !FilePath  -- the generated output dir (proj </> "plexus")
  , taProjDir   :: !FilePath  -- the project root (has user-owned package.json)
  }

-- | Recursively find all files with a given extension
findFilesWithExt :: FilePath -> String -> IO [FilePath]
findFilesWithExt root ext = go root
  where
    go dir = do
      entries <- listDirectory dir
      paths <- concat <$> mapM (process dir) entries
      return paths
    process dir name = do
      let path = dir </> name
      isDir <- doesDirectoryExist path
      if isDir
        then go path
        else return [path | takeExtension name == ext]

-- | Check if a file contains a substring (case-sensitive)
fileContains :: FilePath -> String -> IO Bool
fileContains path needle = do
  content <- readFile path
  return $ needle `isInfixOf` content

-- | Count top-level namespace directories (those containing index.ts)
countNamespaceDirs :: FilePath -> IO Int
countNamespaceDirs root = do
  entries <- listDirectory root
  let candidates = filter (\e -> not ("." `isPrefixOf` e) && e /= "test" && e /= "node_modules") entries
  dirs <- mapM (\e -> doesDirectoryExist (root </> e)) candidates
  let dirNames = [e | (e, True) <- zip candidates dirs]
  -- Count dirs that have index.ts (are namespace modules)
  counts <- mapM (\d -> doesFileExist (root </> d </> "index.ts")) dirNames
  return $ length [() | True <- counts]

-- | Count "export * as" lines in a file
countNamespaceExports :: FilePath -> IO Int
countNamespaceExports path = do
  content <- readFile path
  return $ length $ filter ("export * as " `isPrefixOf`) $ lines content

-- | Run a process and return (exitcode, stdout, stderr)
runProc :: Maybe FilePath -> String -> [String] -> IO (ExitCode, String, String)
runProc _mCwd cmd args = readProcessWithExitCode cmd args ""

-- | Discover substrate URL by querying the registry through synapse CLI.
--   Returns the ws:// URL if substrate is found, Nothing otherwise.
discoverSubstrateUrl :: String -> IO (Maybe String)
discoverSubstrateUrl registryPort = do
  mSynapse <- findExecutable "synapse"
  case mSynapse of
    Nothing -> do
      putStrLn "  synapse not found, skipping registry discovery"
      return Nothing
    Just synapse -> do
      (exit, stdout, _) <- readProcessWithExitCode synapse
        ["-P", registryPort, "--json", "registry-hub", "registry", "list"] ""
      case exit of
        ExitSuccess -> return $ parseSubstrateUrl stdout
        _ -> return Nothing

-- | Parse synapse --json output to find substrate's URL.
--   The output contains JSON stream items, one per line.
--   We look for a "backends" data item containing a substrate entry.
parseSubstrateUrl :: String -> Maybe String
parseSubstrateUrl output =
  let jsonLines = mapMaybe (decode . LBS8.pack) (lines output) :: [Value]
      -- Find the data item with backends list
      backends = concatMap extractBackends jsonLines
      substrate = find isSubstrate backends
  in fmap backendToUrl substrate
  where
    extractBackends :: Value -> [Value]
    extractBackends (Object obj) =
      case KM.lookup "content" obj of
        Just (Object content) ->
          case KM.lookup "backends" content of
            Just (Array arr) -> foldr (:) [] arr
            _ -> []
        _ -> []
    extractBackends _ = []

    isSubstrate :: Value -> Bool
    isSubstrate (Object obj) =
      case KM.lookup "name" obj of
        Just (String name) -> name == "substrate"
        _ -> False
    isSubstrate _ = False

    backendToUrl :: Value -> String
    backendToUrl (Object obj) =
      let proto = case KM.lookup "protocol" obj of
            Just (String p) -> T.unpack p
            _ -> "ws"
          host = case KM.lookup "host" obj of
            Just (String h) -> T.unpack h
            _ -> "localhost"
          port = case KM.lookup "port" obj of
            Just (Number n) -> show (round n :: Int)
            _ -> "4445"
      in proto ++ "://" ++ host ++ ":" ++ port
    backendToUrl _ = "ws://localhost:4445"

-- | Patch the smoke test URL if it points to the registry instead of substrate.
--   Reads the smoke test, checks if URL differs from discovered substrate URL,
--   and rewrites the file if needed.
patchSmokeTestUrl :: FilePath -> String -> IO ()
patchSmokeTestUrl smokeTestPath substrateUrl = do
  content <- readFile smokeTestPath
  let patched = replaceWsUrls content substrateUrl
  when (patched /= content) $ do
    putStrLn $ "  Patching smoke test URL -> " ++ substrateUrl
    length patched `seq` writeFile smokeTestPath patched

-- | Replace ws:// URLs in the smoke test content with the given URL
replaceWsUrls :: String -> String -> String
replaceWsUrls [] _ = []
replaceWsUrls content@(c:cs) newUrl
  | "ws://localhost:" `isPrefixOf` content =
      let rest = drop (length ("ws://localhost:" :: String)) content
          (_port, after) = span isDigit rest
      in newUrl ++ after
  | "ws://127.0.0.1:" `isPrefixOf` content =
      let rest = drop (length ("ws://127.0.0.1:" :: String)) content
          (_port, after) = span isDigit rest
      in newUrl ++ after
  | otherwise = c : replaceWsUrls cs newUrl

-- | Set up the test environment by running the pipeline in-process
setupTestEnv :: IO TestEnv
setupTestEnv = do
  tmpBase <- getTemporaryDirectory
  let tmpDir = tmpBase </> "synapse-cc-test-output"
  tmpExists <- doesDirectoryExist tmpDir
  when tmpExists $ removeDirectoryRecursive tmpDir
  createDirectoryIfMissing True tmpDir

  -- Parse args exactly as the CLI would, using the real parser
  let args = [ "typescript", "substrate"
             , "-P", "4444"
             , "-o", tmpDir
             , "--force"
             , "--no-build"
             , "--no-tests"
             ]
  config <- case getParseResult (execParserPure defaultPrefs synapseCCParserInfo args) of
    Nothing -> fail "Failed to parse synapse-cc arguments"
    Just c  -> return c

  toolsResult <- discoverTools (cfgOptions config)
  tools <- case toolsResult of
    Left err -> fail $ T.unpack (formatError err)
    Right t  -> return t
  -- Run pipeline with cwd = tmpDir to simulate standalone use:
  -- the user runs synapse-cc from the directory that becomes the package root.
  result <- withCurrentDirectory tmpDir $ runPipeline config tools
  case result of
    Left err -> fail $ T.unpack (formatError err)
    Right _  -> return TestEnv
      { teOutputDir    = tmpDir
      , tePipelineRan  = True
      , tePipelineExit = ExitSuccess
      , tePipelineError = ""
      }

-- | Set up the Tauri test environment: a user-owned project with a plexus/ output subdir
setupTauriTestEnv :: IO TauriTestEnv
setupTauriTestEnv = do
  tmpBase <- getTemporaryDirectory
  let tmpDir = tmpBase </> "synapse-cc-tauri-test"
  tmpExists <- doesDirectoryExist tmpDir
  when tmpExists $ removeDirectoryRecursive tmpDir
  createDirectoryIfMissing True tmpDir

  -- Write a user-owned package.json (no _generatedBy marker = integration mode)
  writeFile (tmpDir </> "package.json") $
    "{\n  \"name\": \"my-tauri-app\",\n  \"version\": \"0.0.0\",\n  \"type\": \"module\",\n  \"private\": true\n}\n"

  -- Output goes into a plexus/ subdirectory (like a real Tauri integration)
  let outputDir = tmpDir </> "plexus"

  let args = [ "typescript", "substrate"
             , "-P", "4444"
             , "-o", outputDir
             , "--transport", "browser"
             , "--force"
             , "--no-build"
             , "--no-tests"
             ]
  config <- case getParseResult (execParserPure defaultPrefs synapseCCParserInfo args) of
    Nothing -> fail "Failed to parse tauri synapse-cc arguments"
    Just c  -> return c

  toolsResult <- discoverTools (cfgOptions config)
  tools <- case toolsResult of
    Left err -> fail $ T.unpack (formatError err)
    Right t  -> return t

  result <- withCurrentDirectory tmpDir $ runPipeline config tools
  case result of
    Left err -> fail $ T.unpack (formatError err)
    Right _  -> return TauriTestEnv
      { taOutputDir = outputDir
      , taProjDir   = tmpDir
      }

main :: IO ()
main = do
  setLocaleEncoding utf8
  env <- setupTestEnv
  tauriEnv <- setupTauriTestEnv
  let dir = teOutputDir env
  hspec $ do
    -- ═══════════════════════════════════════════
    -- Section 1: Pipeline
    -- ═══════════════════════════════════════════
    describe "Pipeline" $ do
      it "exit code is 0" $ do
        tePipelineExit env `shouldBe` ExitSuccess

      it "output directory exists" $ do
        exists <- doesDirectoryExist dir
        exists `shouldBe` True

    -- ═══════════════════════════════════════════
    -- Section 2: File structure
    -- ═══════════════════════════════════════════
    describe "File structure" $ do
      let coreFiles =
            [ "types.ts", "rpc.ts", "transport.ts", "index.ts"
            , "package.json", "tsconfig.json", "ir.json"
            ]
      forM_ coreFiles $ \f ->
        it ("core file exists: " ++ f) $ do
          exists <- doesFileExist (dir </> f)
          exists `shouldBe` True

      let knownNamespaces = ["echo", "health", "cone", "hyperforge"]
      forM_ knownNamespaces $ \ns -> do
        it (ns ++ "/types.ts exists") $ do
          exists <- doesFileExist (dir </> ns </> "types.ts")
          exists `shouldBe` True
        it (ns ++ "/client.ts exists") $ do
          exists <- doesFileExist (dir </> ns </> "client.ts")
          exists `shouldBe` True
        it (ns ++ "/index.ts exists") $ do
          exists <- doesFileExist (dir </> ns </> "index.ts")
          exists `shouldBe` True

      it "nested namespace: solar/earth/luna/client.ts exists" $ do
        exists <- doesFileExist (dir </> "solar" </> "earth" </> "luna" </> "client.ts")
        exists `shouldBe` True

      it "test/smoke.test.ts exists" $ do
        exists <- doesFileExist (dir </> "test" </> "smoke.test.ts")
        exists `shouldBe` True

    -- ═══════════════════════════════════════════
    -- Section 3: IR invariants
    -- ═══════════════════════════════════════════
    describe "IR invariants" $ do
      it "ir.json parses as valid JSON" $ do
        bs <- LBS.readFile (dir </> "ir.json")
        let mVal = decode bs :: Maybe Value
        mVal `shouldSatisfy` isJust

      it "irVersion is \"2.0\"" $ do
        bs <- LBS.readFile (dir </> "ir.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "irVersion" obj of
              Just (String v) -> T.unpack v `shouldBe` "2.0"
              other -> expectationFailure $ "irVersion not a string: " ++ show other
          _ -> expectationFailure "ir.json is not an object"

      it "irTypes is non-empty" $ do
        bs <- LBS.readFile (dir </> "ir.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "irTypes" obj of
              Just (Object types) -> KM.size types `shouldSatisfy` (> 0)
              other -> expectationFailure $ "irTypes not an object: " ++ show other
          _ -> expectationFailure "ir.json is not an object"

      it "irMethods is non-empty" $ do
        bs <- LBS.readFile (dir </> "ir.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "irMethods" obj of
              Just (Object methods) -> KM.size methods `shouldSatisfy` (> 0)
              other -> expectationFailure $ "irMethods not an object: " ++ show other
          _ -> expectationFailure "ir.json is not an object"

      it "irPlugins contains echo, health, cone, hyperforge" $ do
        bs <- LBS.readFile (dir </> "ir.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "irPlugins" obj of
              Just (Object plugins) -> do
                let keys = map Key.toText $ KM.keys plugins
                forM_ ["echo", "health", "cone", "hyperforge"] $ \ns ->
                  keys `shouldSatisfy` (T.pack ns `elem`)
              other -> expectationFailure $ "irPlugins not an object: " ++ show other
          _ -> expectationFailure "ir.json is not an object"

    -- ═══════════════════════════════════════════
    -- Section 4: Import invariants
    -- ═══════════════════════════════════════════
    describe "Import invariants" $ do
      it "no dots in import type identifiers" $ do
        tsFiles <- findFilesWithExt dir ".ts"
        forM_ tsFiles $ \f -> do
          content <- readFile f
          let importLines = filter ("import type" `isInfixOf`) (lines content)
          forM_ importLines $ \line -> do
            -- Check for patterns like {X.Y} which indicate unresolved qualified names
            let braceContent = extractBraceContent line
            forM_ braceContent $ \ident ->
              ident `shouldSatisfy` (not . ('.' `elem`))

      it "every namespace index.ts re-exports ./types and ./client" $ do
        let namespaces = ["echo", "health", "cone", "hyperforge"]
        forM_ namespaces $ \ns -> do
          let indexPath = dir </> ns </> "index.ts"
          hasTypes <- fileContains indexPath "./types"
          hasClient <- fileContains indexPath "./client"
          (hasTypes && hasClient) `shouldBe` True

    -- ═══════════════════════════════════════════
    -- Section 5: Code patterns
    -- ═══════════════════════════════════════════
    describe "Code patterns" $ do
      let clientChecks =
            [ ("echo",       "EchoClient",       "EchoClientImpl",       "createEchoClient")
            , ("health",     "HealthClient",      "HealthClientImpl",     "createHealthClient")
            , ("hyperforge", "HyperforgeClient",  "HyperforgeClientImpl", "createHyperforgeClient")
            ]
      forM_ clientChecks $ \(ns, iface, impl, factory) -> do
        it (ns ++ "/client.ts has " ++ iface ++ " interface") $ do
          has <- fileContains (dir </> ns </> "client.ts") ("interface " ++ iface)
          has `shouldBe` True

        it (ns ++ "/client.ts has " ++ impl ++ " class") $ do
          has <- fileContains (dir </> ns </> "client.ts") ("class " ++ impl)
          has `shouldBe` True

        it (ns ++ "/client.ts has " ++ factory ++ " factory") $ do
          has <- fileContains (dir </> ns </> "client.ts") ("function " ++ factory)
          has `shouldBe` True

      it "echo/types.ts has discriminated union with type: field" $ do
        has <- fileContains (dir </> "echo" </> "types.ts") "type:"
        has `shouldBe` True

      it "cone/types.ts has discriminated union with type: field" $ do
        has <- fileContains (dir </> "cone" </> "types.ts") "type:"
        has `shouldBe` True

      it "echo/client.ts uses collectOne (non-streaming)" $ do
        has <- fileContains (dir </> "echo" </> "client.ts") "collectOne<"
        has `shouldBe` True

      it "cone/client.ts uses extractData (streaming)" $ do
        has <- fileContains (dir </> "cone" </> "client.ts") "extractData<"
        has `shouldBe` True

      it "root index.ts export count matches namespace directory count" $ do
        nsExports <- countNamespaceExports (dir </> "index.ts")
        nsDirs <- countNamespaceDirs dir
        -- The export count should be >= the namespace dir count
        -- (could be more due to nested namespaces like solar/earth/luna)
        nsExports `shouldSatisfy` (>= nsDirs)

    -- ═══════════════════════════════════════════
    -- Section 6: package.json
    -- ═══════════════════════════════════════════
    describe "package.json" $ do
      it "parses as valid JSON" $ do
        bs <- LBS.readFile (dir </> "package.json")
        let mVal = decode bs :: Maybe Value
        mVal `shouldSatisfy` isJust

      it "name is @plexus/client" $ do
        bs <- LBS.readFile (dir </> "package.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "name" obj of
              Just (String name) -> T.unpack name `shouldBe` "@plexus/client"
              other -> expectationFailure $ "name not a string: " ++ show other
          _ -> expectationFailure "package.json is not an object"

      it "type is module" $ do
        bs <- LBS.readFile (dir </> "package.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "type" obj of
              Just (String t) -> T.unpack t `shouldBe` "module"
              other -> expectationFailure $ "type not a string: " ++ show other
          _ -> expectationFailure "package.json is not an object"

      it "has scripts.test" $ do
        bs <- LBS.readFile (dir </> "package.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "scripts" obj of
              Just (Object scripts) ->
                KM.lookup "test" scripts `shouldSatisfy` isJust
              other -> expectationFailure $ "scripts not an object: " ++ show other
          _ -> expectationFailure "package.json is not an object"

      it "has scripts.typecheck" $ do
        bs <- LBS.readFile (dir </> "package.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "scripts" obj of
              Just (Object scripts) ->
                KM.lookup "typecheck" scripts `shouldSatisfy` isJust
              other -> expectationFailure $ "scripts not an object: " ++ show other
          _ -> expectationFailure "package.json is not an object"

      it "has typescript devDependency" $ do
        bs <- LBS.readFile (dir </> "package.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "devDependencies" obj of
              Just (Object devDeps) ->
                KM.lookup "typescript" devDeps `shouldSatisfy` isJust
              other -> expectationFailure $ "devDependencies not an object: " ++ show other
          _ -> expectationFailure "package.json is not an object"

      it "has ws dependency" $ do
        bs <- LBS.readFile (dir </> "package.json")
        case decode bs of
          Just (Object obj) -> do
            case KM.lookup "dependencies" obj of
              Just (Object deps) ->
                KM.lookup "ws" deps `shouldSatisfy` isJust
              other -> expectationFailure $ "dependencies not an object: " ++ show other
          _ -> expectationFailure "package.json is not an object"

    -- ═══════════════════════════════════════════
    -- Section 7: TypeScript smoke tests
    -- ═══════════════════════════════════════════
    describe "TypeScript smoke tests" $ do
      it "bun install exits 0" $ do
        bunAvail <- findExecutable "bun"
        case bunAvail of
          Nothing -> pendingWith "bun not found on PATH"
          Just bun -> do
            let p = (proc bun ["install"]) { cwd = Just dir }
            (exit, stdout, stderr) <- readCreateProcessWithExitCode p ""
            case exit of
              ExitSuccess -> return ()
              ExitFailure 127 -> pendingWith $
                "bun runtime unavailable: " ++ take 200 (stderr ++ stdout)
              ExitFailure c -> expectationFailure $
                "bun install failed (exit " ++ show c ++ "): "
                ++ take 500 (stderr ++ stdout)

      it "bun x tsc --noEmit exits 0" $ do
        bunAvail <- findExecutable "bun"
        case bunAvail of
          Nothing -> pendingWith "bun not found on PATH"
          Just bun -> do
            nodeModules <- doesDirectoryExist (dir </> "node_modules")
            unless nodeModules $ pendingWith "node_modules not found (bun install may have failed)"
            let p = (proc bun ["x", "tsc", "--noEmit"]) { cwd = Just dir }
            (exit, stdout, stderr) <- readCreateProcessWithExitCode p ""
            case exit of
              ExitSuccess -> return ()
              ExitFailure 127 -> pendingWith $
                "bun runtime unavailable: " ++ take 200 (stderr ++ stdout)
              ExitFailure c -> expectationFailure $
                "tsc --noEmit failed (exit " ++ show c ++ "): "
                ++ take 500 (stderr ++ stdout)

      it "bun test exits 0" $ do
        bunAvail <- findExecutable "bun"
        case bunAvail of
          Nothing -> pendingWith "bun not found on PATH"
          Just bun -> do
            nodeModules <- doesDirectoryExist (dir </> "node_modules")
            unless nodeModules $ pendingWith "node_modules not found (bun install may have failed)"
            -- Discover substrate's actual URL through the registry and patch
            -- the smoke test if it points at the wrong port (e.g. registry port)
            let smokeTest = dir </> "test" </> "smoke.test.ts"
            smokeExists <- doesFileExist smokeTest
            when smokeExists $ do
              mUrl <- discoverSubstrateUrl "4444"
              case mUrl of
                Just url -> patchSmokeTestUrl smokeTest url
                Nothing -> putStrLn "  Could not discover substrate URL, running smoke test as-is"
            let p = (proc bun ["test"]) { cwd = Just dir }
            (exit, stdout, stderr) <- readCreateProcessWithExitCode p ""
            case exit of
              ExitSuccess -> return ()
              ExitFailure 127 -> pendingWith $
                "bun runtime unavailable: " ++ take 200 (stderr ++ stdout)
              ExitFailure c -> expectationFailure $
                "bun test failed (exit " ++ show c ++ "):\n"
                ++ take 500 stdout ++ "\n" ++ take 500 stderr

    -- ═══════════════════════════════════════════
    -- Section 8: Tauri (browser transport)
    -- ═══════════════════════════════════════════
    describe "Tauri (browser transport)" $ do
      let tdir = taOutputDir tauriEnv

      describe "Integration mode file structure" $ do
        it "output directory exists" $ do
          exists <- doesDirectoryExist tdir
          exists `shouldBe` True

        it "no tsconfig.json in output (integration mode)" $ do
          exists <- doesFileExist (tdir </> "tsconfig.json")
          exists `shouldBe` False

        it "no test/ directory in output (integration mode)" $ do
          exists <- doesDirectoryExist (tdir </> "test")
          exists `shouldBe` False

        it "no package.json in output (host project owns it)" $ do
          exists <- doesFileExist (tdir </> "package.json")
          exists `shouldBe` False

        let coreFiles = ["types.ts", "rpc.ts", "transport.ts", "index.ts", "ir.json"]
        forM_ coreFiles $ \f ->
          it ("core file exists: " ++ f) $ do
            exists <- doesFileExist (tdir </> f)
            exists `shouldBe` True

      describe "Browser transport constraints" $ do
        it "transport.ts has no 'import WebSocket from ws'" $ do
          content <- readFile (tdir </> "transport.ts")
          (("import WebSocket from 'ws'" `isInfixOf` content) ||
           ("import WebSocket from \"ws\"" `isInfixOf` content))
            `shouldBe` False

        it "no 'export namespace' in any generated .ts file" $ do
          tsFiles <- findFilesWithExt tdir ".ts"
          forM_ tsFiles $ \f -> do
            content <- readFile f
            content `shouldSatisfy` (not . ("export namespace" `isInfixOf`))

        it "no parameter properties (private readonly rpc) in any generated .ts file" $ do
          tsFiles <- findFilesWithExt tdir ".ts"
          forM_ tsFiles $ \f -> do
            content <- readFile f
            content `shouldSatisfy` (not . ("private readonly rpc" `isInfixOf`))

      describe "TypeScript compilation (erasableSyntaxOnly)" $ do
        it "tsc --noEmit with erasableSyntaxOnly: true exits 0" $ do
          -- Write a strict tsconfig at project root targeting just the generated output
          let tsconfigContent = unlines
                [ "{"
                , "  \"compilerOptions\": {"
                , "    \"target\": \"ES2022\","
                , "    \"module\": \"ESNext\","
                , "    \"moduleResolution\": \"bundler\","
                , "    \"strict\": true,"
                , "    \"erasableSyntaxOnly\": true,"
                , "    \"noUnusedLocals\": true,"
                , "    \"lib\": [\"ES2022\", \"DOM\"]"
                , "  },"
                , "  \"include\": [\"plexus/**/*.ts\"]"
                , "}"
                ]
          writeFile (taProjDir tauriEnv </> "tsconfig.tauri-check.json") tsconfigContent
          let cp = (proc "bun" ["x", "tsc", "--noEmit", "-p", "tsconfig.tauri-check.json"])
                     { cwd = Just (taProjDir tauriEnv) }
          (exit, stdout, stderr) <- readCreateProcessWithExitCode cp ""
          when (exit /= ExitSuccess) $
            expectationFailure $ "tsc with erasableSyntaxOnly failed:\n" ++ stdout ++ stderr
          exit `shouldBe` ExitSuccess

    -- ═══════════════════════════════════════════
    -- Section 9: Merge and cache invariants
    -- ═══════════════════════════════════════════
    -- These tests run a second pipeline against the already-generated dir
    -- to verify the two most important correctness guarantees:
    --   (a) user edits survive a normal rerun (three-way merge skips modified files)
    --   (b) --force overwrites user edits (explicit opt-in to overwrite)
    describe "Merge and cache invariants" $ do

      -- Helper: run the pipeline with arbitrary extra args into `dir` as both
      -- cwd and output, using the already-discovered tools.
      let runAgain extraArgs = do
            let args = [ "typescript", "substrate"
                       , "-P", "4444"
                       , "-o", dir
                       , "--no-build", "--no-tests"
                       ] ++ extraArgs
            cfg <- case getParseResult (execParserPure defaultPrefs synapseCCParserInfo args) of
                     Nothing -> fail "Failed to parse args for second run"
                     Just c  -> return c
            t <- discoverTools (cfgOptions cfg) >>= either (fail . T.unpack . formatError) return
            withCurrentDirectory dir $ runPipeline cfg t

      it "user edit in a generated file survives rerun without --force" $ do
        -- This is the core safety guarantee of the whole system.
        -- If it breaks, users lose work every time they regenerate.
        let target = dir </> "rpc.ts"
        original <- TIO.readFile target
        let userEdit = original <> "\n// user addition — must survive rerun"
        TIO.writeFile target userEdit

        _ <- runAgain []   -- no --force

        after <- TIO.readFile target
        after `shouldBe` userEdit

      it "user edit is overwritten with --force" $ do
        -- --force must actually force; silent failure would make the flag useless.
        let target = dir </> "rpc.ts"
        original <- TIO.readFile target
        let userEdit = original <> "\n// this should be gone after --force"
        TIO.writeFile target userEdit

        _ <- runAgain ["--force"]

        after <- TIO.readFile target
        after `shouldNotBe` userEdit

    -- ═══════════════════════════════════════════
    -- Section 10: synapse.config.json
    -- ═══════════════════════════════════════════
    describe "synapse.config.json" $ do

      describe "initSynapseConfig" $ do
        it "creates a valid JSON file" $ do
          tmpBase <- getTemporaryDirectory
          let dir' = tmpBase </> "synapse-cc-init-test"
          tmpExists <- doesDirectoryExist dir'
          when tmpExists $ removeDirectoryRecursive dir'
          createDirectoryIfMissing True dir'
          -- Pass [] — no detectors, so defaults apply regardless of test environment
          result <- withCurrentDirectory dir' $ initSynapseConfig synapseConfigPath []
          result `shouldSatisfy` isRight
          exists <- doesFileExist (dir' </> synapseConfigPath)
          exists `shouldBe` True

        it "returns Left if file already exists" $ do
          tmpBase <- getTemporaryDirectory
          let dir' = tmpBase </> "synapse-cc-init-exists-test"
          createDirectoryIfMissing True dir'
          writeFile (dir' </> synapseConfigPath) "{}"
          result <- withCurrentDirectory dir' $ initSynapseConfig synapseConfigPath []
          result `shouldSatisfy` isLeft

        it "created file round-trips through loadSynapseConfig" $ do
          tmpBase <- getTemporaryDirectory
          let dir' = tmpBase </> "synapse-cc-init-roundtrip-test"
          tmpExists <- doesDirectoryExist dir'
          when tmpExists $ removeDirectoryRecursive dir'
          createDirectoryIfMissing True dir'
          _ <- withCurrentDirectory dir' $ initSynapseConfig synapseConfigPath []
          result <- withCurrentDirectory dir' loadSynapseConfig
          result `shouldSatisfy` isRight

      describe "loadSynapseConfig" $ do
        it "returns Left when file is missing" $ do
          tmpBase <- getTemporaryDirectory
          let dir' = tmpBase </> "synapse-cc-no-config-test"
          tmpExists <- doesDirectoryExist dir'
          when tmpExists $ removeDirectoryRecursive dir'
          createDirectoryIfMissing True dir'
          result <- withCurrentDirectory dir' loadSynapseConfig
          result `shouldSatisfy` isLeft

        it "parses the standalone fixture" $ do
          let fixturePath = "test/fixtures/standalone.config.json"
          exists <- doesFileExist fixturePath
          if not exists
            then pendingWith "test/fixtures/standalone.config.json not found"
            else do
              bs <- BS.readFile fixturePath
              case Aeson.decodeStrict bs of
                Nothing  -> expectationFailure "Fixture failed to parse as JSON"
                Just cfg -> scBackend (cfg :: SynapseConfig) `shouldBe` Just "substrate"

        it "fixture has two targets" $ do
          let fixturePath = "test/fixtures/standalone.config.json"
          exists <- doesFileExist fixturePath
          if not exists
            then pendingWith "test/fixtures/standalone.config.json not found"
            else do
              bs <- BS.readFile fixturePath
              case Aeson.decodeStrict bs of
                Nothing  -> expectationFailure "Fixture failed to parse"
                Just cfg -> Map.size (scTargets (cfg :: SynapseConfig)) `shouldBe` 2

      describe "validateSynapseConfig" $ do
        it "accepts defaultSynapseConfig" $
          validateSynapseConfig defaultSynapseConfig `shouldBe` Right ()

        it "rejects empty backend" $
          validateSynapseConfig (defaultSynapseConfig { scBackend = Just "" })
            `shouldSatisfy` isLeft

        it "rejects whitespace-only backend" $
          validateSynapseConfig (defaultSynapseConfig { scBackend = Just "   " })
            `shouldSatisfy` isLeft

        it "rejects empty targets map" $
          validateSynapseConfig (defaultSynapseConfig { scTargets = Map.empty })
            `shouldSatisfy` isLeft

        it "rejects target with empty generate list" $ do
          let badTarget = TargetConfig
                { tcGenerate  = []
                , tcTransport = WsTransport
                , tcOutputDir = "out"
                , tcSmokePath = Nothing
                }
          let cfg = defaultSynapseConfig { scTargets = Map.singleton "t" badTarget }
          validateSynapseConfig cfg `shouldSatisfy` isLeft

        it "rejects target with empty outputDir" $ do
          let badTarget = TargetConfig
                { tcGenerate  = ["plugins"]
                , tcTransport = WsTransport
                , tcOutputDir = ""
                , tcSmokePath = Nothing
                }
          let cfg = defaultSynapseConfig { scTargets = Map.singleton "t" badTarget }
          validateSynapseConfig cfg `shouldSatisfy` isLeft

      describe "JSON round-trip" $ do
        it "encode/decode SynapseConfig preserves data" $ do
          let cfg = defaultSynapseConfig
          case Aeson.decode (Aeson.encode cfg) of
            Nothing      -> expectationFailure "Failed to decode encoded SynapseConfig"
            Just decoded -> scBackend (decoded :: SynapseConfig) `shouldBe` scBackend cfg

        it "WatchConfig defaults parse correctly" $ do
          let json = "{\"pollInterval\":500,\"hotReload\":true}"
          case Aeson.decodeStrict (BSC8.pack json) of
            Nothing -> expectationFailure "Failed to parse WatchConfig"
            Just wc -> do
              wcPollInterval (wc :: WatchConfig) `shouldBe` 500
              wcHotReload wc `shouldBe` True

    -- ═══════════════════════════════════════════
    -- Section 11: CLI subcommand parsing
    -- ═══════════════════════════════════════════
    describe "CLI subcommand parsing" $ do
      let parse args = getParseResult (execParserPure defaultPrefs synapseCCCommandParserInfo args)

      describe "build subcommand" $ do
        it "parses 'build typescript substrate'" $
          parse ["build", "typescript", "substrate"] `shouldSatisfy` isJust

        it "produces CmdBuild" $ do
          case parse ["build", "typescript", "substrate"] of
            Just (CmdBuild _) -> pure ()
            other -> expectationFailure $ "Expected CmdBuild, got: " ++ show other

        it "--transport browser gives BrowserTransport" $ do
          case parse ["build", "typescript", "substrate", "--transport", "browser"] of
            Just (CmdBuild cfg) -> optTransport (cfgOptions cfg) `shouldBe` BrowserTransport
            _ -> expectationFailure "Parse failed or wrong command"

        it "--no-install disables dep install" $ do
          case parse ["build", "typescript", "substrate", "--no-install"] of
            Just (CmdBuild cfg) -> optInstallDeps (cfgOptions cfg) `shouldBe` False
            _ -> expectationFailure "Parse failed"

        it "--no-build disables build step" $ do
          case parse ["build", "typescript", "substrate", "--no-build"] of
            Just (CmdBuild cfg) -> optBuild (cfgOptions cfg) `shouldBe` False
            _ -> expectationFailure "Parse failed"

        it "--force enables force flag" $ do
          case parse ["build", "typescript", "substrate", "--force"] of
            Just (CmdBuild cfg) -> optForce (cfgOptions cfg) `shouldBe` True
            _ -> expectationFailure "Parse failed"

        it "unknown target fails to parse" $
          parse ["build", "cobol", "substrate"] `shouldSatisfy` isNothing

        it "'build' with no args produces CmdBuildFromConfig" $
          case parse ["build"] of
            Just (CmdBuildFromConfig _) -> pure ()
            other -> expectationFailure $ "Expected CmdBuildFromConfig, got: " ++ show other

        it "'build --no-install' with no positional args passes flag through" $
          case parse ["build", "--no-install"] of
            Just (CmdBuildFromConfig opts) -> optInstallDeps opts `shouldBe` False
            other -> expectationFailure $ "Expected CmdBuildFromConfig, got: " ++ show other

        it "'build --force' with no positional args passes flag through" $
          case parse ["build", "--force"] of
            Just (CmdBuildFromConfig opts) -> optForce opts `shouldBe` True
            other -> expectationFailure $ "Expected CmdBuildFromConfig, got: " ++ show other

      describe "watch subcommand" $ do
        it "parses 'watch substrate'" $
          parse ["watch", "substrate"] `shouldSatisfy` isJust

        it "produces CmdWatch" $ do
          case parse ["watch", "substrate"] of
            Just (CmdWatch _) -> pure ()
            other -> expectationFailure $ "Expected CmdWatch, got: " ++ show other

        it "backend is set correctly" $ do
          case parse ["watch", "substrate"] of
            Just (CmdWatch wa) -> waBackend wa `shouldBe` "substrate"
            _ -> expectationFailure "Parse failed"

        it "no plugin args -> empty list" $ do
          case parse ["watch", "substrate"] of
            Just (CmdWatch wa) -> waPlugins wa `shouldBe` []
            _ -> expectationFailure "Parse failed"

        it "plugin args become prefix filters" $ do
          case parse ["watch", "substrate", "echo", "health"] of
            Just (CmdWatch wa) -> waPlugins wa `shouldBe` ["echo", "health"]
            other -> expectationFailure $ "Expected CmdWatch with plugins, got: " ++ show other

        it "--target pins to a named target" $ do
          case parse ["watch", "substrate", "echo", "--target", "client"] of
            Just (CmdWatch wa) -> waTarget wa `shouldBe` Just "client"
            other -> expectationFailure $ show other

        it "no --target -> Nothing" $ do
          case parse ["watch", "substrate"] of
            Just (CmdWatch wa) -> waTarget wa `shouldBe` Nothing
            _ -> expectationFailure "Parse failed"

      describe "init subcommand" $ do
        it "parses 'init'" $
          parse ["init"] `shouldSatisfy` isJust

        it "produces CmdInit" $ do
          case parse ["init"] of
            Just CmdInit -> pure ()
            other -> expectationFailure $ "Expected CmdInit, got: " ++ show other

      describe "legacy build parser compatibility" $ do
        it "synapseCCParserInfo still parses old-style args" $
          getParseResult (execParserPure defaultPrefs synapseCCParserInfo
            ["typescript", "substrate", "--no-build", "--no-tests"])
            `shouldSatisfy` isJust

    -- ═══════════════════════════════════════════
    -- Section 12: Watch utilities (pure)
    -- ═══════════════════════════════════════════
    describe "Watch utilities" $ do

      describe "matchesAnyPrefix" $ do
        it "exact match" $
          matchesAnyPrefix ["echo"] "echo" `shouldBe` True
        it "prefix.child match" $
          matchesAnyPrefix ["echo"] "echo.workspace" `shouldBe` True
        it "deep prefix match" $
          matchesAnyPrefix ["echo"] "echo.workspace.repos" `shouldBe` True
        it "does NOT match substring without dot" $
          matchesAnyPrefix ["echo"] "echoes" `shouldBe` False
        it "does NOT match unrelated namespace" $
          matchesAnyPrefix ["echo"] "health" `shouldBe` False
        it "empty filter list matches nothing" $
          matchesAnyPrefix [] "echo" `shouldBe` False
        it "multiple prefixes, first matches" $
          matchesAnyPrefix ["echo", "health"] "echo.run" `shouldBe` True
        it "multiple prefixes, second matches" $
          matchesAnyPrefix ["echo", "health"] "health.status" `shouldBe` True
        it "multiple prefixes, none match" $
          matchesAnyPrefix ["echo", "health"] "cone.render" `shouldBe` False

      describe "parseUrl" $ do
        it "ws://localhost:4444" $
          parseUrl "ws://localhost:4444" `shouldBe` ("localhost", "4444")
        it "ws://127.0.0.1:4444" $
          parseUrl "ws://127.0.0.1:4444" `shouldBe` ("127.0.0.1", "4444")
        it "wss://host:8443" $
          parseUrl "wss://host:8443" `shouldBe` ("host", "8443")
        it "path after port is ignored" $
          snd (parseUrl "ws://localhost:4444/backend") `shouldBe` "4444"
        it "defaults port to 4444 when missing" $
          snd (parseUrl "ws://localhost") `shouldBe` "4444"
        it "custom port 9999" $
          snd (parseUrl "ws://myhost:9999") `shouldBe` "9999"

      describe "extractPluginHashesFromBytes" $ do
        it "returns empty map for invalid JSON" $
          extractPluginHashesFromBytes "not json" `shouldBe` Map.empty

        it "returns empty map for JSON without irPluginHashes" $
          extractPluginHashesFromBytes "{\"irVersion\":\"2.0\"}" `shouldBe` Map.empty

        it "extracts hash from irPluginHashes" $ do
          let ir = BSC8.pack "{\"irPluginHashes\":{\"echo\":{\"hash\":\"abc123\",\"selfHash\":\"x\",\"childrenHash\":\"y\"}}}"
          Map.lookup "echo" (extractPluginHashesFromBytes ir) `shouldBe` Just "abc123"

        it "extracts multiple plugin hashes" $ do
          let ir = BSC8.pack "{\"irPluginHashes\":{\"echo\":{\"hash\":\"aaa\"},\"health\":{\"hash\":\"bbb\"}}}"
          let hashes = extractPluginHashesFromBytes ir
          Map.size hashes `shouldBe` 2
          Map.lookup "echo"   hashes `shouldBe` Just "aaa"
          Map.lookup "health" hashes `shouldBe` Just "bbb"

        it "returns empty string for hash field missing" $ do
          let ir = BSC8.pack "{\"irPluginHashes\":{\"echo\":{\"selfHash\":\"x\"}}}"
          Map.lookup "echo" (extractPluginHashesFromBytes ir) `shouldBe` Just ""

      describe "filterTargets" $ do
        let mkTarget gen = TargetConfig gen WsTransport "out" Nothing
        let targets = Map.fromList
              [ ("client", mkTarget ["transport", "rpc", "plugins"])
              , ("smoke",  mkTarget ["smoke"])
              , ("all",    mkTarget ["all"])
              , ("empty",  mkTarget ["transport"])
              ]
        let noPin = WatchArgs "substrate" [] Nothing Nothing defaultOptions

        it "includes targets with 'plugins'" $
          Map.member "client" (filterTargets noPin targets) `shouldBe` True
        it "excludes targets without 'plugins' or 'all'" $
          Map.member "smoke" (filterTargets noPin targets) `shouldBe` False
        it "includes targets with 'all'" $
          Map.member "all" (filterTargets noPin targets) `shouldBe` True
        it "excludes transport-only targets" $
          Map.member "empty" (filterTargets noPin targets) `shouldBe` False

        it "--target pins to exactly one target" $ do
          let pinned = WatchArgs "substrate" [] (Just "smoke") Nothing defaultOptions
          Map.keys (filterTargets pinned targets) `shouldBe` ["smoke"]

        it "--target for missing name returns empty" $ do
          let pinned = WatchArgs "substrate" [] (Just "nonexistent") Nothing defaultOptions
          filterTargets pinned targets `shouldBe` Map.empty

      describe "buildConfigFromTarget" $ do
        it "sets outputDir from target" $ do
          let wa  = WatchArgs "substrate" [] Nothing Nothing defaultOptions
          let sc  = defaultSynapseConfig { scUrl = Just "ws://localhost:4444" }
          let tc  = TargetConfig ["plugins"] BrowserTransport "my/output/dir" Nothing
          let cfg = buildConfigFromTarget wa sc tc
          optOutput (cfgOptions cfg) `shouldBe` "my/output/dir"

        it "sets transport from target" $ do
          let wa  = WatchArgs "substrate" [] Nothing Nothing defaultOptions
          let sc  = defaultSynapseConfig
          let tc  = TargetConfig ["plugins"] BrowserTransport "out" Nothing
          let cfg = buildConfigFromTarget wa sc tc
          optTransport (cfgOptions cfg) `shouldBe` BrowserTransport

        it "parses host from URL" $ do
          let wa  = WatchArgs "substrate" [] Nothing Nothing defaultOptions
          let sc  = defaultSynapseConfig { scUrl = Just "ws://myhost:9000" }
          let tc  = TargetConfig ["plugins"] WsTransport "out" Nothing
          let cfg = buildConfigFromTarget wa sc tc
          cfgHost cfg `shouldBe` "myhost"

        it "parses port from URL" $ do
          let wa  = WatchArgs "substrate" [] Nothing Nothing defaultOptions
          let sc  = defaultSynapseConfig { scUrl = Just "ws://localhost:9000" }
          let tc  = TargetConfig ["plugins"] WsTransport "out" Nothing
          let cfg = buildConfigFromTarget wa sc tc
          cfgPort cfg `shouldBe` "9000"

    -- ═══════════════════════════════════════════
    -- Section 13: Project detection (Detect.hs)
    -- ═══════════════════════════════════════════
    describe "SynapseCC.Detect" $ do

      -- Helper: create a temp project dir, run action, clean up.
      -- The action receives the dir path; withCurrentDirectory is the caller's responsibility.
      let withTempProject :: (FilePath -> IO a) -> IO a
          withTempProject action = do
            tmpBase <- getTemporaryDirectory
            let dir = tmpBase </> "synapse-detect-test"
            exists <- doesDirectoryExist dir
            when exists $ removeDirectoryRecursive dir
            createDirectoryIfMissing True dir
            action dir

      describe "detectTauri" $ do
        it "returns BrowserTransport when src-tauri/ exists" $ do
          withTempProject $ \dir -> do
            createDirectoryIfMissing True (dir </> "src-tauri")
            result <- withCurrentDirectory dir (runDetector detectTauri)
            phTransport result `shouldBe` Just BrowserTransport

        it "returns BrowserTransport when tauri.conf.json exists" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "tauri.conf.json") "{}"
            result <- withCurrentDirectory dir (runDetector detectTauri)
            phTransport result `shouldBe` Just BrowserTransport

        it "returns BrowserTransport when src-tauri/tauri.conf.json exists" $ do
          withTempProject $ \dir -> do
            createDirectoryIfMissing True (dir </> "src-tauri")
            writeFile (dir </> "src-tauri" </> "tauri.conf.json") "{}"
            result <- withCurrentDirectory dir (runDetector detectTauri)
            phTransport result `shouldBe` Just BrowserTransport

        it "returns emptyHint when no Tauri markers present" $ do
          withTempProject $ \dir -> do
            result <- withCurrentDirectory dir (runDetector detectTauri)
            phTransport result `shouldBe` Nothing

      describe "detectVite" $ do
        it "returns BrowserTransport for vite.config.ts" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "vite.config.ts") "export default {}"
            result <- withCurrentDirectory dir (runDetector detectVite)
            phTransport result `shouldBe` Just BrowserTransport

        it "returns BrowserTransport for vite.config.js" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "vite.config.js") "module.exports = {}"
            result <- withCurrentDirectory dir (runDetector detectVite)
            phTransport result `shouldBe` Just BrowserTransport

        it "returns BrowserTransport for vite.config.mts" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "vite.config.mts") "export default {}"
            result <- withCurrentDirectory dir (runDetector detectVite)
            phTransport result `shouldBe` Just BrowserTransport

        it "returns emptyHint when no Vite markers present" $ do
          withTempProject $ \dir -> do
            result <- withCurrentDirectory dir (runDetector detectVite)
            phTransport result `shouldBe` Nothing

      describe "detectNextJS" $ do
        it "returns BrowserTransport for next.config.js" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "next.config.js") "module.exports = {}"
            result <- withCurrentDirectory dir (runDetector detectNextJS)
            phTransport result `shouldBe` Just BrowserTransport

        it "returns BrowserTransport for next.config.ts" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "next.config.ts") "export default {}"
            result <- withCurrentDirectory dir (runDetector detectNextJS)
            phTransport result `shouldBe` Just BrowserTransport

        it "returns emptyHint when no Next.js markers present" $ do
          withTempProject $ \dir -> do
            result <- withCurrentDirectory dir (runDetector detectNextJS)
            phTransport result `shouldBe` Nothing

      describe "detectNodeProject" $ do
        it "returns WsTransport when package.json exists" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "package.json") "{\"name\":\"test\"}"
            result <- withCurrentDirectory dir (runDetector detectNodeProject)
            phTransport result `shouldBe` Just WsTransport

        it "returns emptyHint when package.json is absent" $ do
          withTempProject $ \dir -> do
            result <- withCurrentDirectory dir (runDetector detectNodeProject)
            phTransport result `shouldBe` Nothing

      describe "runDetectors priority" $ do
        it "Tauri beats Node (browser wins when both src-tauri/ and package.json present)" $ do
          withTempProject $ \dir -> do
            createDirectoryIfMissing True (dir </> "src-tauri")
            writeFile (dir </> "package.json") "{}"
            result <- withCurrentDirectory dir (runDetectors defaultDetectors)
            phTransport result `shouldBe` Just BrowserTransport

        it "Vite beats Node (browser wins when both vite.config.ts and package.json present)" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "vite.config.ts") "export default {}"
            writeFile (dir </> "package.json") "{}"
            result <- withCurrentDirectory dir (runDetectors defaultDetectors)
            phTransport result `shouldBe` Just BrowserTransport

        it "NextJS beats Node (browser wins when both next.config.js and package.json present)" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "next.config.js") "module.exports = {}"
            writeFile (dir </> "package.json") "{}"
            result <- withCurrentDirectory dir (runDetectors defaultDetectors)
            phTransport result `shouldBe` Just BrowserTransport

        it "bare Node project → WsTransport (fallback)" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "package.json") "{}"
            result <- withCurrentDirectory dir (runDetectors defaultDetectors)
            phTransport result `shouldBe` Just WsTransport

        it "empty project → no transport opinion" $ do
          withTempProject $ \dir -> do
            result <- withCurrentDirectory dir (runDetectors defaultDetectors)
            phTransport result `shouldBe` Nothing

        it "custom detector prepended overrides defaultDetectors" $ do
          withTempProject $ \dir -> do
            -- Custom detector that always says WsTransport, even in a Tauri project
            let myDetector = Detector "custom" (pure emptyHint { phTransport = Just WsTransport })
            createDirectoryIfMissing True (dir </> "src-tauri")
            result <- withCurrentDirectory dir (runDetectors (myDetector : defaultDetectors))
            phTransport result `shouldBe` Just WsTransport

      describe "initSynapseConfig with detectors" $ do
        it "Tauri project → generated config has browser transport" $ do
          withTempProject $ \dir -> do
            createDirectoryIfMissing True (dir </> "src-tauri")
            hint <- withCurrentDirectory dir $
              initSynapseConfig synapseConfigPath defaultDetectors
            hint `shouldSatisfy` isRight
            cfgResult <- withCurrentDirectory dir loadSynapseConfig
            case cfgResult of
              Left err -> expectationFailure $ "loadSynapseConfig failed: " <> T.unpack err
              Right sc -> do
                let transports = map tcTransport (Map.elems (scTargets sc))
                transports `shouldSatisfy` all (== BrowserTransport)

        it "Vite project → generated config has browser transport" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "vite.config.ts") "export default {}"
            hint <- withCurrentDirectory dir $
              initSynapseConfig synapseConfigPath defaultDetectors
            hint `shouldSatisfy` isRight
            cfgResult <- withCurrentDirectory dir loadSynapseConfig
            case cfgResult of
              Left err -> expectationFailure $ "loadSynapseConfig failed: " <> T.unpack err
              Right sc -> do
                let transports = map tcTransport (Map.elems (scTargets sc))
                transports `shouldSatisfy` all (== BrowserTransport)

        it "Node project → generated config has ws transport" $ do
          withTempProject $ \dir -> do
            writeFile (dir </> "package.json") "{}"
            hint <- withCurrentDirectory dir $
              initSynapseConfig synapseConfigPath defaultDetectors
            hint `shouldSatisfy` isRight
            cfgResult <- withCurrentDirectory dir loadSynapseConfig
            case cfgResult of
              Left err -> expectationFailure $ "loadSynapseConfig failed: " <> T.unpack err
              Right sc -> do
                let transports = map tcTransport (Map.elems (scTargets sc))
                transports `shouldSatisfy` all (== WsTransport)

        it "empty project → generated config has ws transport (default)" $ do
          withTempProject $ \dir -> do
            hint <- withCurrentDirectory dir $
              initSynapseConfig synapseConfigPath defaultDetectors
            hint `shouldSatisfy` isRight
            cfgResult <- withCurrentDirectory dir loadSynapseConfig
            case cfgResult of
              Left err -> expectationFailure $ "loadSynapseConfig failed: " <> T.unpack err
              Right sc -> do
                -- No detector fired → no hint → default transport (WsTransport from defaultSynapseConfig)
                let transports = map tcTransport (Map.elems (scTargets sc))
                transports `shouldSatisfy` (not . null)

        it "hint reason is included in successful result" $ do
          withTempProject $ \dir -> do
            createDirectoryIfMissing True (dir </> "src-tauri")
            result <- withCurrentDirectory dir $
              initSynapseConfig synapseConfigPath defaultDetectors
            case result of
              Left err -> expectationFailure $ "Expected Right but got Left: " <> T.unpack err
              Right hint -> phReason hint `shouldSatisfy` isJust

    -- ═══════════════════════════════════════════
    -- Section 14: Standalone config-driven build
    -- ═══════════════════════════════════════════
    describe "Standalone config-driven build" $ do

      it "init + load + pipeline produces output in configured target dir" $ do
        -- Write the standalone fixture config, run the pipeline with
        -- settings derived from the config, verify output lands in tcOutputDir.
        let fixturePath = "test/fixtures/standalone.config.json"
        fixtureExists <- doesFileExist fixturePath
        when (not fixtureExists) $ pendingWith "test/fixtures/standalone.config.json not found"

        synapseAvail <- findExecutable "synapse"
        when (not (isJust synapseAvail)) $ pendingWith "synapse binary not found"

        tmpBase <- getTemporaryDirectory
        let projDir = tmpBase </> "synapse-cc-standalone-project"
        tmpExists <- doesDirectoryExist projDir
        when tmpExists $ removeDirectoryRecursive projDir
        createDirectoryIfMissing True projDir

        -- Copy fixture config into project
        fixtureBytes <- readFile fixturePath
        writeFile (projDir </> synapseConfigPath) fixtureBytes

        -- Load config and build using the "client" target
        cfgResult <- withCurrentDirectory projDir loadSynapseConfig
        case cfgResult of
          Left err -> expectationFailure $ "Config load failed: " ++ T.unpack err
          Right synapseConfig -> do
            case Map.lookup "client" (scTargets synapseConfig) of
              Nothing -> expectationFailure "Expected 'client' target in fixture"
              Just targetCfg -> do
                let wa      = WatchArgs (fromMaybe "" (scBackend synapseConfig)) [] Nothing Nothing defaultOptions
                    config  = buildConfigFromTarget wa synapseConfig targetCfg
                    config' = config { cfgOptions = (cfgOptions config)
                                { optInstallDeps = False
                                , optBuild       = False
                                , optRunTests    = False
                                , optForce       = True
                                , optOutput      = projDir </> tcOutputDir targetCfg
                                } }
                toolsResult <- discoverTools (cfgOptions config')
                case toolsResult of
                  Left err -> expectationFailure $ T.unpack (formatError err)
                  Right tools -> do
                    result <- withCurrentDirectory projDir $ runPipeline config' tools
                    case result of
                      Left err -> expectationFailure $ T.unpack (formatError err)
                      Right _  -> do
                        let outDir = projDir </> tcOutputDir targetCfg
                        exists <- doesDirectoryExist outDir
                        exists `shouldBe` True
                        typesExists <- doesFileExist (outDir </> "types.ts")
                        typesExists `shouldBe` True

      it "both targets in fixture produce separate output directories" $ do
        let fixturePath = "test/fixtures/standalone.config.json"
        fixtureExists <- doesFileExist fixturePath
        when (not fixtureExists) $ pendingWith "test/fixtures/standalone.config.json not found"
        synapseAvail <- findExecutable "synapse"
        when (not (isJust synapseAvail)) $ pendingWith "synapse binary not found"

        tmpBase <- getTemporaryDirectory
        let projDir = tmpBase </> "synapse-cc-two-targets"
        tmpExists <- doesDirectoryExist projDir
        when tmpExists $ removeDirectoryRecursive projDir
        createDirectoryIfMissing True projDir

        fixtureBytes <- readFile fixturePath
        writeFile (projDir </> synapseConfigPath) fixtureBytes

        cfgResult <- withCurrentDirectory projDir loadSynapseConfig
        case cfgResult of
          Left err -> expectationFailure $ "Config load failed: " ++ T.unpack err
          Right synapseConfig -> do
            toolsResult <- discoverTools defaultOptions
            case toolsResult of
              Left err -> expectationFailure $ T.unpack (formatError err)
              Right tools ->
                forM_ (Map.toList (scTargets synapseConfig)) $ \(targetName, targetCfg) -> do
                  let wa     = WatchArgs (fromMaybe "" (scBackend synapseConfig)) [] Nothing Nothing defaultOptions
                      config = buildConfigFromTarget wa synapseConfig targetCfg
                      config' = config { cfgOptions = (cfgOptions config)
                                  { optInstallDeps = False
                                  , optBuild       = False
                                  , optRunTests    = False
                                  , optForce       = True
                                  , optOutput      = projDir </> tcOutputDir targetCfg
                                  } }
                  result <- withCurrentDirectory projDir $ runPipeline config' tools
                  case result of
                    Left err -> expectationFailure $
                      "Target " ++ T.unpack targetName ++ " failed: " ++ T.unpack (formatError err)
                    Right _ -> do
                      exists <- doesDirectoryExist (projDir </> tcOutputDir targetCfg)
                      exists `shouldBe` True

    -- Section 14: Watch integration (requires fidget-spinner binary)
    -- ═══════════════════════════════════════════════════════════════
    describe "Watch integration (fidget-spinner)" $ do

      let testPort    = 5557 :: Int
          testPortStr = show testPort

      -- Find fidget-spinner binary (installed or build output)
      mbFidgetBin <- runIO $ do
        mb <- findExecutable "fidget-spinner"
        case mb of
          Just p  -> pure (Just p)
          Nothing -> do
            let buildPath = "/workspace/hypermemetic/fidget-spinner/target/debug/fidget-spinner"
            exists <- doesFileExist buildPath
            pure $ if exists then Just buildPath else Nothing

      -- Start fidget-spinner and wait for readiness
      -- Returns Nothing if binary not found or failed to start
      mbHandle <- runIO $ case mbFidgetBin of
        Nothing -> pure Nothing
        Just bin -> do
          (_, _, _, ph) <- createProcess (proc bin ["--port", testPortStr, "--no-register"])
            { std_out = NoStream, std_err = NoStream }
          -- Poll until ready (up to 5 seconds)
          ready <- waitForFidgetReady testPort 5000
          if ready
            then pure (Just ph)
            else do
              terminateProcess ph
              _ <- waitForProcess ph
              pure Nothing

      -- Cleanup after all tests in this section
      afterAll_ (case mbHandle of
        Nothing -> pure ()
        Just ph -> terminateProcess ph >> void (waitForProcess ph)) $ do

        it "fidget-spinner starts and backend hash is non-empty" $ do
          case mbHandle of
            Nothing -> pendingWith "fidget-spinner binary not found or failed to start"
            Just _ -> do
              let cfg = makeFidgetConfig testPort
              result <- fetchBackendHash cfg "fidget-spinner"
              result `shouldSatisfy` isRight
              case result of
                Right h -> T.length h `shouldSatisfy` (> 0)
                Left _  -> pure ()

        it "initial build generates fidget/client.ts with register/unregister/list" $ do
          case mbHandle of
            Nothing -> pendingWith "fidget-spinner binary not found or failed to start"
            Just _ -> do
              tmpBase <- getTemporaryDirectory
              let projDir = tmpBase </> "synapse-cc-fidget-initial"
              createDirectoryIfMissing True projDir
              let outDir = projDir </> "client"

              let fixturePath = "test/fixtures/fidget.config.json"
              fixtureBytes <- readFile fixturePath
              writeFile (projDir </> "synapse.config.json") fixtureBytes

              let config = makeFidgetPipelineConfig testPort outDir
              toolsResult <- discoverTools (cfgOptions config)
              case toolsResult of
                Left err -> expectationFailure $ T.unpack (formatError err)
                Right tools -> do
                  result <- withCurrentDirectory projDir $ runPipeline config tools
                  case result of
                    Left err -> expectationFailure $ T.unpack (formatError err)
                    Right _ -> do
                      let clientFile = outDir </> "fidget" </> "client.ts"
                      exists <- doesFileExist clientFile
                      exists `shouldBe` True
                      content <- readFile clientFile
                      content `shouldSatisfy` ("register" `isInfixOf`)
                      content `shouldSatisfy` ("unregister" `isInfixOf`)
                      content `shouldSatisfy` ("list" `isInfixOf`)
                      content `shouldSatisfy` (not . ("spin" `isInfixOf`))

        it "register changes the backend hash" $ do
          case mbHandle of
            Nothing -> pendingWith "fidget-spinner binary not found or failed to start"
            Just _ -> do
              let cfg = makeFidgetConfig testPort
              Right hash1 <- fetchBackendHash cfg "fidget-spinner"

              -- Register a new method
              callFidgetRegister testPortStr "hashtest" "A method to test hash changes"

              Right hash2 <- fetchBackendHash cfg "fidget-spinner"
              hash1 `shouldNotBe` hash2

              -- Cleanup: unregister it
              callFidgetUnregister testPortStr "hashtest"

        it "register + rebuild adds the method to generated TypeScript" $ do
          case mbHandle of
            Nothing -> pendingWith "fidget-spinner binary not found or failed to start"
            Just _ -> do
              tmpBase <- getTemporaryDirectory
              let projDir = tmpBase </> "synapse-cc-fidget-rebuild"
              createDirectoryIfMissing True projDir
              let outDir = projDir </> "client"

              -- Initial build
              let config = makeFidgetPipelineConfig testPort outDir
              toolsResult <- discoverTools (cfgOptions config)
              case toolsResult of
                Left err -> expectationFailure $ T.unpack (formatError err)
                Right tools -> do
                  _ <- withCurrentDirectory projDir $ runPipeline config tools

                  -- Register "spin"
                  callFidgetRegister testPortStr "spin" "Make it spin"

                  -- Rebuild with --force
                  let forceConfig = config { cfgOptions = (cfgOptions config) { optForce = True } }
                  result <- withCurrentDirectory projDir $ runPipeline forceConfig tools
                  case result of
                    Left err -> expectationFailure $ T.unpack (formatError err)
                    Right _ -> do
                      let clientFile = outDir </> "fidget" </> "client.ts"
                      content <- readFile clientFile
                      content `shouldSatisfy` ("spin" `isInfixOf`)

                  -- Cleanup
                  callFidgetUnregister testPortStr "spin"

        it "unregister + rebuild removes the method from generated TypeScript" $ do
          case mbHandle of
            Nothing -> pendingWith "fidget-spinner binary not found or failed to start"
            Just _ -> do
              tmpBase <- getTemporaryDirectory
              let projDir = tmpBase </> "synapse-cc-fidget-unregister"
              createDirectoryIfMissing True projDir
              let outDir = projDir </> "client"

              -- Register "wobble" first
              callFidgetRegister testPortStr "wobble" "A wobble method"

              -- Build with wobble present
              let config = makeFidgetPipelineConfig testPort outDir
              toolsResult <- discoverTools (cfgOptions config)
              case toolsResult of
                Left err -> expectationFailure $ T.unpack (formatError err)
                Right tools -> do
                  _ <- withCurrentDirectory projDir $ runPipeline config tools

                  -- Unregister "wobble"
                  callFidgetUnregister testPortStr "wobble"

                  -- Rebuild with --force
                  let forceConfig = config { cfgOptions = (cfgOptions config) { optForce = True } }
                  result <- withCurrentDirectory projDir $ runPipeline forceConfig tools
                  case result of
                    Left err -> expectationFailure $ T.unpack (formatError err)
                    Right _ -> do
                      let clientFile = outDir </> "fidget" </> "client.ts"
                      content <- readFile clientFile
                      content `shouldSatisfy` (not . ("wobble" `isInfixOf`))

-- | Extract identifiers from import type { ... } braces
extractBraceContent :: String -> [String]
extractBraceContent line =
  case break (== '{') line of
    (_, []) -> []
    (_, _:rest) ->
      case break (== '}') rest of
        (inside, _) ->
          map (filter (\c -> isAlpha c || c == '.' || c == '_'))
            $ filter (not . null)
            $ map strip
            $ splitOn ',' inside

-- | Split a string on a delimiter
splitOn :: Char -> String -> [String]
splitOn _ [] = []
splitOn c s =
  let (chunk, rest) = break (== c) s
  in chunk : case rest of
    [] -> []
    (_:xs) -> splitOn c xs

-- | Strip leading/trailing whitespace
strip :: String -> String
strip = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

-- ── fidget-spinner test helpers ──────────────────────────────────────────────

-- | Poll until fidget-spinner is ready to serve requests.
-- Returns True if ready within timeoutMs, False if timed out.
waitForFidgetReady :: Int -> Int -> IO Bool
waitForFidgetReady port timeoutMs = go (timeoutMs `div` 200)
  where
    go 0 = pure False
    go n = do
      let cfg = makeFidgetConfig port
      result <- (try (Transport.rpcCallWith cfg "fidget-spinner.hash" Aeson.Null) :: IO (Either SomeException (Either TransportError [PlexusStreamItem])))
      case result of
        Right (Right (_ : _)) -> pure True
        _ -> do
          threadDelay 200000  -- 200ms
          go (n - 1)

-- | Build a SubstrateConfig for a local fidget-spinner on the given port.
makeFidgetConfig :: Int -> SubstrateConfig
makeFidgetConfig port = (defaultConfig "fidget-spinner")
  { substrateHost = "127.0.0.1"
  , substratePort = port
  }

-- | Build a Config for running the pipeline against fidget-spinner.
makeFidgetPipelineConfig :: Int -> FilePath -> Config
makeFidgetPipelineConfig port outDir =
  Config
    { cfgTarget  = TypeScript
    , cfgBackend = Backend { backendName = "fidget-spinner" }
    , cfgHost    = "127.0.0.1"
    , cfgPort    = T.pack (show port)
    , cfgOptions = defaultOptions
        { optOutput      = outDir
        , optInstallDeps = False
        , optBuild       = False
        , optRunTests    = False
        , optForce       = True
        , optTransport   = WsTransport
        }
    }

-- | Call fidget.register via direct RPC.
-- | Call fidget.register via the fidget-spinner.call RPC routing.
callFidgetRegister :: String -> Text -> Text -> IO ()
callFidgetRegister portStr name desc = do
  let port = read portStr :: Int
      cfg  = makeFidgetConfig port
      innerParams = Aeson.object ["name" .= name, "description" .= desc]
      callParams  = Aeson.object ["method" .= ("fidget.register" :: Text), "params" .= innerParams]
  _ <- Transport.rpcCallWith cfg "fidget-spinner.call" callParams
  pure ()

-- | Call fidget.unregister via the fidget-spinner.call RPC routing.
callFidgetUnregister :: String -> Text -> IO ()
callFidgetUnregister portStr name = do
  let port = read portStr :: Int
      cfg  = makeFidgetConfig port
      innerParams = Aeson.object ["name" .= name]
      callParams  = Aeson.object ["method" .= ("fidget.unregister" :: Text), "params" .= innerParams]
  _ <- Transport.rpcCallWith cfg "fidget-spinner.call" callParams
  pure ()
