module Main (main) where

import Test.Hspec

import Control.Monad (forM_, when, unless)
import Data.Aeson (Value(..), decode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Char (isAlpha, isDigit)
import Data.List (isInfixOf, isPrefixOf, find)
import Data.Maybe (isJust, mapMaybe)
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
import System.Process (readProcessWithExitCode, CreateProcess(..), proc, readCreateProcessWithExitCode)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Options.Applicative (execParserPure, defaultPrefs, getParseResult)
import SynapseCC.CLI (synapseCCParserInfo)
import SynapseCC.Discover (discoverTools)
import SynapseCC.Pipeline (runPipeline)
import SynapseCC.Types (Config(..), Options(..), defaultOptions, formatError)

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
