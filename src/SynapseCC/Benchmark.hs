{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Pipeline step benchmarking with regression detection.
--
-- After the first successful run, step timings are written to a JSON baseline
-- file inside the cache directory. Every subsequent run compares against that
-- baseline and emits a warning for any step that regresses by more than the
-- configured threshold.
module SynapseCC.Benchmark
  ( -- * Timing
    timeStep

    -- * Baseline management
  , loadBaseline
  , saveBaseline
  , baselinePath

    -- * Regression reporting
  , reportBenchmarks

    -- * Types
  , Baseline(..)
  , StepTiming(..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), takeDirectory)

-- ============================================================================
-- Types
-- ============================================================================

data StepTiming = StepTiming
  { stName :: !Text
  , stMs   :: !Int
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (FromJSON, ToJSON)

data Baseline = Baseline
  { blVersion    :: !Text
  , blBackend    :: !Text
  , blTarget     :: !Text
  , blRecordedAt :: !Text
  , blSteps      :: !(Map Text Int)  -- step name -> baseline ms
  , blTotalMs    :: !Int
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ============================================================================
-- Timing
-- ============================================================================

-- | Run an action and return its result paired with elapsed milliseconds.
timeStep :: IO a -> IO (a, Int)
timeStep action = do
  t0 <- getCurrentTime
  result <- action
  t1 <- getCurrentTime
  let ms = round (diffUTCTime t1 t0 * 1000) :: Int
  pure (result, ms)

-- ============================================================================
-- Baseline I/O
-- ============================================================================

-- | Canonical path for the baseline file.
baselinePath :: FilePath  -- ^ cache dir (optCacheDir)
             -> Text      -- ^ target  (e.g. "typescript")
             -> Text      -- ^ backend (e.g. "substrate")
             -> FilePath
baselinePath cacheDir target backend =
  cacheDir </> "benchmarks" </> T.unpack target </> T.unpack backend <> ".json"

-- | Load a baseline from disk.  Returns Nothing if the file doesn't exist or
-- can't be parsed.
loadBaseline :: FilePath -> IO (Maybe Baseline)
loadBaseline path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      bytes <- BL.readFile path
      case Aeson.eitherDecode bytes of
        Left  _  -> pure Nothing   -- corrupted — treat as missing
        Right bl -> pure (Just bl)

-- | Write a baseline to disk, creating parent directories as needed.
saveBaseline :: FilePath -> Baseline -> IO ()
saveBaseline path bl = do
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (Aeson.encode bl)

-- ============================================================================
-- Regression detection
-- ============================================================================

-- | Regression threshold: warn when a step is this many percent slower than
-- baseline AND at least this many milliseconds slower (avoids noise on fast
-- steps).
regressionPct :: Int
regressionPct = 25

regressionMinMs :: Int
regressionMinMs = 200

-- | Compare a run's step timings against a baseline.
-- Returns (regressions, improvements) as lists of human-readable lines.
checkRegressions :: Map Text Int  -- ^ baseline step times
                 -> Map Text Int  -- ^ actual step times
                 -> ([Text], [Text])
checkRegressions baseline actual =
  Map.foldlWithKey' classify ([], []) actual
  where
    classify (regs, imps) step ms =
      case Map.lookup step baseline of
        Nothing -> (regs, imps)  -- new step, no baseline yet
        Just baseMs ->
          let delta    = ms - baseMs
              pct      = (delta * 100) `div` max 1 baseMs
              label    = padStep step <> T.pack (show ms) <> "ms"
                       <> " (baseline " <> T.pack (show baseMs) <> "ms"
                       <> ", " <> showDelta delta <> ")"
          in if delta > regressionMinMs && pct > regressionPct
               then (label : regs, imps)
               else if delta < negate regressionMinMs
                      then (regs, label : imps)
                      else (regs, imps)

    showDelta d
      | d > 0    = "+" <> T.pack (show d) <> "ms"
      | otherwise = T.pack (show d) <> "ms"

    padStep s = s <> T.replicate (max 1 (24 - T.length s)) " "

-- ============================================================================
-- Public reporting
-- ============================================================================

-- | Called at the end of a successful pipeline run.
--
-- Behaviour:
--  * If no baseline exists: save current timings as the new baseline and
--    print a "baseline recorded" notice.
--  * If a baseline exists: compare, print a timing table, warn on regressions,
--    and update the baseline for any step that improved.
reportBenchmarks
  :: FilePath       -- ^ baseline file path
  -> Text           -- ^ backend name
  -> Text           -- ^ target name
  -> Text           -- ^ ISO-8601 timestamp
  -> Map Text Int   -- ^ step timings (ms)
  -> Int            -- ^ total pipeline ms
  -> IO ()
reportBenchmarks path backend target ts steps totalMs = do
  mbBaseline <- loadBaseline path

  case mbBaseline of
    Nothing -> do
      -- First run — record baseline
      let bl = Baseline
            { blVersion    = "1"
            , blBackend    = backend
            , blTarget     = target
            , blRecordedAt = ts
            , blSteps      = steps
            , blTotalMs    = totalMs
            }
      saveBaseline path bl
      putStrLn $ "\n[bench] Baseline recorded (" <> show totalMs <> "ms total)"
      putStrLn   "[bench] Future runs will compare against this baseline."

    Just bl -> do
      let (regs, imps) = checkRegressions (blSteps bl) steps

      -- Always print the timing table
      putStrLn "\n[bench] Step timings:"
      mapM_ (\(k, v) -> putStrLn $ "  " <> T.unpack (padStep k) <> show v <> "ms") (Map.toAscList steps)
      putStrLn $ "  " <> T.unpack (padStep "total") <> show totalMs <> "ms"
      putStrLn $ "  baseline total: " <> show (blTotalMs bl) <> "ms"

      -- Report regressions
      if null regs
        then putStrLn "[bench] No regressions."
        else do
          putStrLn "\n[bench] ⚠  REGRESSIONS DETECTED:"
          mapM_ (\r -> putStrLn $ "  " <> T.unpack r) regs

      -- Report improvements
      mapM_ (\i -> putStrLn $ "[bench] ✓ faster: " <> T.unpack i) imps

      -- Update baseline: keep the minimum (best) time per step, update total
      -- if this run was faster overall.
      let mergedSteps = Map.unionWith min steps (blSteps bl)
          newTotal    = min totalMs (blTotalMs bl)
          bl'         = bl { blSteps = mergedSteps, blTotalMs = newTotal, blRecordedAt = ts }
      saveBaseline path bl'
  where
    padStep s = s <> T.replicate (max 1 (20 - T.length s)) " "
