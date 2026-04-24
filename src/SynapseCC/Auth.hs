{-# LANGUAGE OverloadedStrings #-}

-- | Token resolution for synapse-cc (SAFE-2; deduplicated in SELF-6).
--
-- This module is the CLI-priority chain that sits in front of the shared
-- 'Synapse.Self.resolveToken' helper. The chain (highest first):
--
--   1. @--token \<jwt\>@                       (explicit flag)
--   2. @SYNAPSE_TOKEN@ env var
--   3. @--token-file \<path\>@                 (explicit file)
--   4. 'Synapse.Self.resolveToken' — reads
--      @~\/.plexus\/\<backend\>\/defaults.json@ via 'defaultRegistry'
--
-- Step 4 delegates through the shared library so synapse and synapse-cc
-- stay byte-identical on persistent defaults. Prior to SELF-6 this
-- module carried a hand-rolled copy of the defaults.json read; SELF-6
-- collapses that onto 'Synapse.Self.resolveToken'.
--
-- 'SynapseCC.Auth.resolveToken' itself stays as a synapse-cc-local
-- orchestrator because 'Options' is a synapse-cc type — the Options
-- record and the CLI flag priority belong here, not in the library.
-- The /library-visible/ fallback is what SELF-6 dedups.
module SynapseCC.Auth
  ( resolveToken
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (lookupEnv)

import qualified Synapse.Self as Self

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
        _ -> case optTokenFile opts of
          Just p -> do
            contents <- TIO.readFile p
            let tok = T.strip contents
            pure $ if T.null tok then Nothing else Just tok
          Nothing -> Self.resolveToken backend
