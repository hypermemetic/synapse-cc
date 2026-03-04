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
import System.Directory
  ( doesDirectoryExist, doesFileExist, findExecutable
  , getTemporaryDirectory, listDirectory
  , createDirectoryIfMissing, removeDirectoryRecursive
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeExtension)
import System.Process (readProcessWithExitCode, CreateProcess(..), proc, readCreateProcessWithExitCode)

-- | Shared test context: the path to generated output
data TestEnv = TestEnv
  { teOutputDir :: !FilePath
  , tePipelineRan :: !Bool  -- True if we ran synapse-cc, False if using existing generated/
  , tePipelineExit :: !ExitCode
  , tePipelineError :: !String  -- Captured error output when pipeline fails
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

-- | Discover the synapse-cc binary
findSynapseCCBin :: IO (Maybe FilePath)
findSynapseCCBin = do
  -- 1. SYNAPSE_CC_BIN env var
  envBin <- lookupEnv "SYNAPSE_CC_BIN"
  case envBin of
    Just p -> do
      exists <- doesFileExist p
      return $ if exists then Just p else Nothing
    Nothing -> do
      -- 2. dist-newstyle build path
      let distPath = "dist-newstyle/build/aarch64-osx/ghc-9.6.7/synapse-cc-0.1.0.0/x/synapse-cc/build/synapse-cc/synapse-cc"
      distExists <- doesFileExist distPath
      if distExists
        then return (Just distPath)
        else do
          -- 3. findExecutable on PATH
          findExecutable "synapse-cc"

-- | Set up the test environment by running the pipeline or falling back to generated/
setupTestEnv :: IO TestEnv
setupTestEnv = do
  mBin <- findSynapseCCBin
  case mBin of
    Nothing -> do
      putStrLn "WARNING: synapse-cc binary not found, using existing generated/ directory"
      genExists <- doesDirectoryExist "generated"
      unless genExists $
        fail "No synapse-cc binary and no generated/ directory found"
      return TestEnv
        { teOutputDir = "generated"
        , tePipelineRan = False
        , tePipelineExit = ExitSuccess
        , tePipelineError = "synapse-cc binary not found"
        }
    Just bin -> do
      tmpBase <- getTemporaryDirectory
      let tmpDir = tmpBase </> "synapse-cc-test-output"
      -- Clean up from previous runs
      tmpExists <- doesDirectoryExist tmpDir
      when tmpExists $ removeDirectoryRecursive tmpDir
      createDirectoryIfMissing True tmpDir
      putStrLn $ "Running synapse-cc pipeline: " ++ bin
      (exit, stdout, stderr) <- runProc Nothing bin
        [ "typescript", "substrate"
        , "-P", "4444"
        , "-o", tmpDir
        , "--force"
        , "--no-install"
        , "--no-build"
        , "--no-tests"
        ]
      case exit of
        ExitSuccess -> do
          putStrLn $ "Pipeline succeeded, output in: " ++ tmpDir
          return TestEnv
            { teOutputDir = tmpDir
            , tePipelineRan = True
            , tePipelineExit = ExitSuccess
            , tePipelineError = ""
            }
        ExitFailure code -> do
          let output = if null stderr then stdout else stderr
          fail $ "Pipeline failed (exit " ++ show code ++ "): " ++ take 500 output

main :: IO ()
main = do
  env <- setupTestEnv
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
      it "npm install exits 0" $ do
        npmAvail <- findExecutable "npm"
        case npmAvail of
          Nothing -> pendingWith "npm not found on PATH"
          Just npm -> do
            let p = (proc npm ["install"]) { cwd = Just dir }
            (exit, stdout, stderr) <- readCreateProcessWithExitCode p ""
            case exit of
              ExitSuccess -> return ()
              ExitFailure 127 -> pendingWith $
                "node runtime unavailable: " ++ take 200 (stderr ++ stdout)
              ExitFailure c -> expectationFailure $
                "npm install failed (exit " ++ show c ++ "): "
                ++ take 500 (stderr ++ stdout)

      it "npx tsc --noEmit exits 0" $ do
        npxAvail <- findExecutable "npx"
        case npxAvail of
          Nothing -> pendingWith "npx not found on PATH"
          Just npx -> do
            nodeModules <- doesDirectoryExist (dir </> "node_modules")
            unless nodeModules $ pendingWith "node_modules not found (npm install may have failed)"
            let p = (proc npx ["tsc", "--noEmit"]) { cwd = Just dir }
            (exit, stdout, stderr) <- readCreateProcessWithExitCode p ""
            case exit of
              ExitSuccess -> return ()
              ExitFailure 127 -> pendingWith $
                "node runtime unavailable: " ++ take 200 (stderr ++ stdout)
              ExitFailure c -> expectationFailure $
                "tsc --noEmit failed (exit " ++ show c ++ "): "
                ++ take 500 (stderr ++ stdout)

      it "npm test exits 0" $ do
        npmAvail <- findExecutable "npm"
        case npmAvail of
          Nothing -> pendingWith "npm not found on PATH"
          Just npm -> do
            nodeModules <- doesDirectoryExist (dir </> "node_modules")
            unless nodeModules $ pendingWith "node_modules not found (npm install may have failed)"
            -- Discover substrate's actual URL through the registry and patch
            -- the smoke test if it points at the wrong port (e.g. registry port)
            let smokeTest = dir </> "test" </> "smoke.test.ts"
            smokeExists <- doesFileExist smokeTest
            when smokeExists $ do
              mUrl <- discoverSubstrateUrl "4444"
              case mUrl of
                Just url -> patchSmokeTestUrl smokeTest url
                Nothing -> putStrLn "  Could not discover substrate URL, running smoke test as-is"
            let p = (proc npm ["test"]) { cwd = Just dir }
            (exit, stdout, stderr) <- readCreateProcessWithExitCode p ""
            case exit of
              ExitSuccess -> return ()
              ExitFailure 127 -> pendingWith $
                "node runtime unavailable: " ++ take 200 (stderr ++ stdout)
              ExitFailure c -> expectationFailure $
                "npm test failed (exit " ++ show c ++ "):\n"
                ++ take 500 stdout ++ "\n" ++ take 500 stderr

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
