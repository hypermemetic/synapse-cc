{-# LANGUAGE OverloadedStrings #-}

-- | Three-way merge for generated files.
-- Preserves user modifications while applying generator updates safely.
module SynapseCC.Merge
  ( computeFileHash
  , applyMerge
  , cleanRemovedFiles
  , additiveMerge
  , MergeResult(..)
  ) where

import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Control.Exception (try, SomeException)
import Data.Maybe (catMaybes)
import System.Directory ( createDirectoryIfMissing, doesFileExist
                        , removeFile, listDirectory, removeDirectory )
import System.FilePath ((</>), takeDirectory)

-- | Compute SHA-256 hash of text content, returning first 16 hex characters.
-- Algorithm matches hub-codegen hash.rs: SHA-256(utf8_bytes)[..16] as lowercase hex.
computeFileHash :: Text -> Text
computeFileHash content =
  T.take 16 $ TE.decodeUtf8 $ Base16.encode $ SHA256.hash $ TE.encodeUtf8 content

data FileStatus
  = NewFile
  | SafeToUpdate
  | Unchanged
  | UserModified
  | SmartMerged
  deriving (Show, Eq)

-- | Three-way merge decision table:
--
--   cached  | current | new  | status
--   --------+---------+------+---------------
--   ∅       | ∅       | any  | NewFile
--   any     | ∅       | any  | SafeToUpdate (restore deleted file)
--   ∅       | H       | H    | Unchanged
--   ∅       | H       | H2   | NewFile
--   H1==H1  | same    | same | Unchanged
--   H1==H1  | same    | H2   | SafeToUpdate
--   H1      | H2≠H1   | any  | UserModified (skip)
determineStatus :: Maybe Text -> Maybe Text -> Text -> FileStatus
determineStatus Nothing   Nothing      _new = NewFile
determineStatus (Just _)  Nothing      _new = SafeToUpdate
determineStatus Nothing   (Just curr)  new
  | curr == new = Unchanged
  | otherwise   = NewFile
determineStatus (Just cached) (Just curr) new
  | cached == curr = if curr == new then Unchanged else SafeToUpdate
  | otherwise      = UserModified

-- | Result of applying a merge
data MergeResult = MergeResult
  { mrNew          :: [Text]      -- ^ New files written
  , mrUpdated      :: [Text]      -- ^ Existing files safely updated
  , mrUnchanged    :: [Text]      -- ^ Files unchanged (write skipped)
  , mrSkipped      :: [Text]      -- ^ Files skipped due to user modifications
  , mrDeleted      :: [Text]      -- ^ Stale generated files removed
  , mrMerged       :: [Text]      -- ^ Files smart-merged (new content added, user mods preserved)
  , mrMergedHashes :: Map Text Text  -- ^ relPath -> merged hash for smart-merged files
  } deriving (Show, Eq)

-- | Apply three-way merge: write generated files to disk, skipping user-modified ones.
applyMerge
  :: Map Text Text  -- ^ Generated file contents (relPath -> content)
  -> Map Text Text  -- ^ Generated file hashes   (relPath -> hash, unused but kept for API symmetry)
  -> Map Text Text  -- ^ Cached file hashes       (relPath -> hash)
  -> FilePath       -- ^ Output directory
  -> IO MergeResult
applyMerge generatedFiles _generatedHashes cachedHashes outputDir = do
  results <- mapM processFile (Map.toList generatedFiles)
  pure $ foldr addResult emptyResult results
  where
    emptyResult = MergeResult [] [] [] [] [] [] Map.empty

    processFile (relPath, content) = do
      let fullPath   = outputDir </> T.unpack relPath
          newHash    = computeFileHash content
          cachedHash = Map.lookup relPath cachedHashes
      currentHash <- readCurrentHash fullPath
      let status = determineStatus cachedHash currentHash newHash
      case status of
        NewFile      -> writeFile' fullPath content >> pure (relPath, NewFile, Nothing)
        SafeToUpdate -> writeFile' fullPath content >> pure (relPath, SafeToUpdate, Nothing)
        Unchanged    -> pure (relPath, Unchanged, Nothing)
        SmartMerged  -> pure (relPath, SmartMerged, Nothing)  -- not reached from determineStatus
        UserModified -> do
          currentBytes <- BS.readFile fullPath
          let currentContent = TE.decodeUtf8With TEE.lenientDecode currentBytes
          case additiveMerge content currentContent of
            Just merged -> do
              writeFile' fullPath merged
              let mergedHash = computeFileHash merged
              pure (relPath, SmartMerged, Just mergedHash)
            Nothing -> pure (relPath, UserModified, Nothing)

    readCurrentHash path = do
      exists <- doesFileExist path
      if exists
        then do
          bytes <- BS.readFile path
          pure $ Just $ computeFileHash $ TE.decodeUtf8With TEE.lenientDecode bytes
        else pure Nothing

    writeFile' path content = do
      createDirectoryIfMissing True (takeDirectory path)
      BS.writeFile path (TE.encodeUtf8 content)

    addResult (p, NewFile, _)      mr = mr { mrNew       = p : mrNew       mr }
    addResult (p, SafeToUpdate, _) mr = mr { mrUpdated   = p : mrUpdated   mr }
    addResult (p, Unchanged, _)    mr = mr { mrUnchanged = p : mrUnchanged mr }
    addResult (p, UserModified, _) mr = mr { mrSkipped   = p : mrSkipped   mr }
    addResult (p, SmartMerged, mh) mr = mr
      { mrMerged       = p : mrMerged mr
      , mrMergedHashes = case mh of
          Just h  -> Map.insert p h (mrMergedHashes mr)
          Nothing -> mrMergedHashes mr
      }

-- | Additive merge: insert novel lines from new content into user-modified current content.
-- Returns Nothing if files are too divergent (<50% shared lines) or an anchor can't be found.
additiveMerge :: Text -> Text -> Maybe Text
additiveMerge newContent currentContent
  | newLines == currentLines = Just currentContent  -- identical, no-op
  | sharedRatio < 0.5       = Nothing               -- too divergent
  | null insertionBlocks    = Just currentContent    -- no novel lines
  | otherwise               = applyInsertions currentLines insertionBlocks
  where
    newLines     = T.lines newContent
    currentLines = T.lines currentContent
    currentSet   = Set.fromList currentLines

    -- Count how many new lines exist in current
    sharedCount  = length $ filter (`Set.member` currentSet) newLines
    sharedRatio  = fromIntegral sharedCount / max 1 (fromIntegral (length newLines)) :: Double

    -- Walk newLines, grouping consecutive novel lines with their anchor
    -- An anchor is the last shared line before a block of novel lines
    insertionBlocks = extractBlocks Nothing [] [] newLines

    -- Extract insertion blocks: (Maybe anchor, [novel lines])
    extractBlocks :: Maybe Text -> [(Maybe Text, [Text])] -> [Text] -> [Text] -> [(Maybe Text, [Text])]
    extractBlocks _anchor acc novelAcc [] =
      if null novelAcc then reverse acc
      else reverse ((Nothing, reverse novelAcc) : acc)  -- trailing novel lines get no anchor
    extractBlocks anchor acc novelAcc (l:ls)
      | l `Set.member` currentSet =
          let acc' = if null novelAcc then acc
                     else (anchor, reverse novelAcc) : acc
          in extractBlocks (Just l) acc' [] ls
      | otherwise =
          extractBlocks anchor acc (l : novelAcc) ls

    -- Apply insertion blocks into currentLines
    applyInsertions :: [Text] -> [(Maybe Text, [Text])] -> Maybe Text
    applyInsertions curr blocks = go curr blocks 0
      where
        go :: [Text] -> [(Maybe Text, [Text])] -> Int -> Maybe Text
        go remaining [] _ = Just $ T.unlines (remaining)
        go remaining ((Nothing, novel):rest) pos =
          -- No anchor: prepend to result (novel lines before any shared line)
          go (novel ++ remaining) rest pos
        go remaining ((Just anchor, novel):rest) pos =
          -- Find anchor in remaining lines (forward scan)
          case findAnchor anchor remaining of
            Nothing -> Nothing  -- can't find anchor, bail
            Just idx ->
              let (before, afterAnchor) = splitAt (idx + 1) remaining
                  remaining' = before ++ novel ++ afterAnchor
                  newPos = pos + idx + 1 + length novel
              in go remaining' rest newPos

    -- Find first occurrence of anchor line in a list
    findAnchor :: Text -> [Text] -> Maybe Int
    findAnchor _anchor [] = Nothing
    findAnchor anchor ls  = go' 0 ls
      where
        go' _ []     = Nothing
        go' i (x:xs) = if x == anchor then Just i else go' (i + 1) xs

-- | Delete stale generated files: those present in the previous generation's
-- cached hashes but absent from the new generation.
--
-- A file is only deleted if it hasn't been modified since the last generation
-- (current hash == cached hash). User-modified files are left untouched.
--
-- After file deletion, empty parent directories are pruned up to (but not
-- including) the output root.
cleanRemovedFiles
  :: Map Text Text  -- ^ Old cached file hashes (previous generation)
  -> Map Text Text  -- ^ New generated file hashes (current generation)
  -> FilePath       -- ^ Output directory
  -> IO [Text]      -- ^ Paths of deleted files (relative)
cleanRemovedFiles oldHashes newHashes outputDir = do
  let stale = Map.keys $ Map.difference oldHashes newHashes
  deleted <- mapM tryDelete stale
  pure (catMaybes deleted)
  where
    tryDelete relPath = do
      let fullPath   = outputDir </> T.unpack relPath
          cachedHash = Map.findWithDefault "" relPath oldHashes
      exists <- doesFileExist fullPath
      if not exists
        then pure Nothing  -- already gone
        else do
          bytes <- BS.readFile fullPath
          let current = computeFileHash $ TE.decodeUtf8With TEE.lenientDecode bytes
          if current /= cachedHash
            then pure Nothing  -- user-modified: leave it
            else do
              removeFile fullPath
              pruneEmptyDirs (takeDirectory fullPath) outputDir
              pure (Just relPath)

-- | Remove empty directories walking upward, stopping at the output root.
pruneEmptyDirs :: FilePath -> FilePath -> IO ()
pruneEmptyDirs dir root
  | dir == root || length dir <= length root = pure ()
  | otherwise = do
      contentsResult <- try (listDirectory dir) :: IO (Either SomeException [FilePath])
      case contentsResult of
        Left _         -> pure ()
        Right []       -> do
          _ <- try (removeDirectory dir) :: IO (Either SomeException ())
          pruneEmptyDirs (takeDirectory dir) root
        Right _nonempty -> pure ()
