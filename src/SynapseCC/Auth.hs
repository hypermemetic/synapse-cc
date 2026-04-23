{-# LANGUAGE OverloadedStrings #-}

-- | Token resolution for synapse-cc (SAFE-2).
--
-- Mirrors the token-resolution chain in @synapse/app/Main.hs@ but adds
-- @SYNAPSE_TOKEN@ env var support. SAFE-S03 tracks deduplication once
-- @resolveToken@ is moved into the synapse library.
--
-- Priority (highest first):
--
--   1. @--token <jwt>@                       (explicit flag)
--   2. @SYNAPSE_TOKEN@ env var               (added by SAFE-2)
--   3. @--token-file <path>@                 (explicit file)
--   4. @~\/.plexus\/tokens\/\<backend\>@     (per-backend default)
--
-- Token files contain just the raw JWT, optionally with a trailing newline.
module SynapseCC.Auth
  ( resolveToken
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import SynapseCC.Types (Options(..))

-- | Resolve the auth token for a given backend.
-- Returns 'Nothing' if no source provides one.
resolveToken :: Options -> Text -> IO (Maybe Text)
resolveToken opts backend =
  case optToken opts of
    Just tok | not (T.null tok) -> pure (Just tok)
    _ -> do
      mEnv <- lookupEnv "SYNAPSE_TOKEN"
      case mEnv of
        Just envTok | not (null envTok) -> pure (Just (T.pack envTok))
        _ -> do
          mPath <- case optTokenFile opts of
            Just p  -> pure (Just p)
            Nothing -> do
              home <- getHomeDirectory
              let defaultPath = home </> ".plexus" </> "tokens" </> T.unpack backend
              exists <- doesFileExist defaultPath
              pure $ if exists then Just defaultPath else Nothing
          case mPath of
            Nothing   -> pure Nothing
            Just path -> do
              contents <- TIO.readFile path
              let tok = T.strip contents
              pure $ if T.null tok then Nothing else Just tok
