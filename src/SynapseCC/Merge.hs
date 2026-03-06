{-# LANGUAGE OverloadedStrings #-}

-- | Three-way merge for generated files.
-- Preserves user modifications while applying generator updates safely.
module SynapseCC.Merge
  ( computeFileHash
  , applyMerge
  , MergeResult(..)
  ) where

import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import System.Directory (createDirectoryIfMissing, doesFileExist)
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
  { mrNew       :: [Text]  -- ^ New files written
  , mrUpdated   :: [Text]  -- ^ Existing files safely updated
  , mrUnchanged :: [Text]  -- ^ Files unchanged (write skipped)
  , mrSkipped   :: [Text]  -- ^ Files skipped due to user modifications
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
    emptyResult = MergeResult [] [] [] []

    processFile (relPath, content) = do
      let fullPath   = outputDir </> T.unpack relPath
          newHash    = computeFileHash content
          cachedHash = Map.lookup relPath cachedHashes
      currentHash <- readCurrentHash fullPath
      let status = determineStatus cachedHash currentHash newHash
      case status of
        NewFile      -> writeFile' fullPath content >> pure (relPath, NewFile)
        SafeToUpdate -> writeFile' fullPath content >> pure (relPath, SafeToUpdate)
        Unchanged    -> pure (relPath, Unchanged)
        UserModified -> pure (relPath, UserModified)

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

    addResult (p, NewFile)      mr = mr { mrNew       = p : mrNew       mr }
    addResult (p, SafeToUpdate) mr = mr { mrUpdated   = p : mrUpdated   mr }
    addResult (p, Unchanged)    mr = mr { mrUnchanged = p : mrUnchanged mr }
    addResult (p, UserModified) mr = mr { mrSkipped   = p : mrSkipped   mr }
