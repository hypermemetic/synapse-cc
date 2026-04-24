{-# LANGUAGE OverloadedStrings #-}

-- | Token resolution for synapse-cc (SAFE-2).
--
-- Mirrors the token-resolution chain in @synapse/app/Main.hs@ but adds
-- @SYNAPSE_TOKEN@ env var support. SAFE-S03 tracks full deduplication;
-- it completes when SELF-6 collapses this module into a thin re-export
-- of @Synapse.Self@.
--
-- Priority (highest first):
--
--   1. @--token <jwt>@                       (explicit flag)
--   2. @SYNAPSE_TOKEN@ env var               (added by SAFE-2)
--   3. @--token-file <path>@                 (explicit file)
--   4. @cookies.access_token@ in @~\/.plexus\/\<backend\>\/defaults.json@
--      (resolved through 'Synapse.Self.defaultRegistry')
--
-- Step 4 was @~\/.plexus\/tokens\/\<backend\>@ prior to SELF-3. That
-- file is now auto-migrated to @defaults.json@ on first
-- 'Synapse.Self.loadDefaults' call, so the final fallback here just
-- delegates — no direct reads of the legacy path remain in synapse-cc.
--
-- Token files (step 3) contain just the raw JWT, optionally with a
-- trailing newline.
module SynapseCC.Auth
  ( resolveToken
  ) where

import qualified Control.Exception as E
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

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
          Nothing -> resolveFromDefaults backend

-- | Load the backend's @defaults.json@ and, if it carries a
-- @cookies.access_token@ ref, resolve it through
-- 'Synapse.Self.defaultRegistry'.
--
-- Any IO or resolve failure degrades to 'Nothing' with a stderr hint —
-- the caller will surface \"no token available\" further up. We never
-- block an unauthenticated request here on a resolver glitch; callers
-- that actually need auth will fail their request and the hint text
-- from 'Synapse.Transport' points the user at the fix.
resolveFromDefaults :: Text -> IO (Maybe Text)
resolveFromDefaults backend = do
  eStored <- E.try (Self.loadDefaults backend) :: IO (Either E.IOException Self.StoredDefaults)
  case eStored of
    Left _ -> pure Nothing
    Right stored -> case Map.lookup "access_token" (Self.sdCookies stored) of
      Nothing  -> pure Nothing
      Just ref -> do
        r <- Self.resolveRef Self.defaultRegistry ref
        case r of
          Right tok | not (T.null tok) -> pure (Just tok)
          Right _ -> pure Nothing
          Left err -> do
            hPutStrLn stderr $
              "[WARN] failed to resolve cookies.access_token for backend '"
              <> T.unpack backend <> "': " <> show err
            pure Nothing
