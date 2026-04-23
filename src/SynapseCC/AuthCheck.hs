{-# LANGUAGE OverloadedStrings #-}

-- | SAFE-6: detect backends that require cookie-based WebSocket auth
-- and warn when the target's generated @transport.ts@ lacks the
-- SAFE-7 cookie-auth marker.
--
-- Detection signal: the IR contains at least one method whose params
-- schema has a property annotated @x-plexus-source.from = "auth"@.
-- That annotation is emitted by REQ-6 from @#[from_auth(...)]@ method
-- params. Any presence means the backend is using cookie-driven auth
-- at dispatch time; clients without cookie support will fail silently.
--
-- The SAFE-7 marker is the string @SAFE-7-cookie-auth-marker@ embedded
-- in the transport template by @hub-codegen@'s TS generator. Its
-- presence in an existing @transport.ts@ indicates the file was
-- produced by a SAFE-7-era hub-codegen (i.e. cookie-capable).
module SynapseCC.AuthCheck
  ( detectCookieAuthMismatch
  , backendRequiresCookieAuth
  ) where

import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | The marker string embedded by SAFE-7 in @transport.ts@. Kept in
-- sync with @hub-codegen/src/generator/typescript/transport.rs@.
safe7Marker :: Text
safe7Marker = "SAFE-7-cookie-auth-marker"

-- | Inspect the IR JSON at @irFile@ and the target's output directory
-- @outputDir@. Returns @Just warningText@ when the backend requires
-- cookie auth (any method has @x-plexus-source.from = "auth"@) AND an
-- existing @transport.ts@ in the output directory lacks the SAFE-7
-- marker. Returns @Nothing@ otherwise (including first builds where
-- no transport.ts exists — nothing to mismatch with yet).
detectCookieAuthMismatch
  :: FilePath  -- ^ IR JSON file (e.g. cache's ir.json)
  -> FilePath  -- ^ Target output directory (will inspect transport.ts inside)
  -> IO (Maybe Text)
detectCookieAuthMismatch irFile outputDir = do
  irBytes <- BS.readFile irFile
  case Aeson.eitherDecodeStrict irBytes of
    Left _    -> pure Nothing  -- unreadable IR is not this module's problem
    Right (val :: Value) ->
      if backendRequiresCookieAuth val
        then inspectTarget outputDir
        else pure Nothing

-- | Returns 'True' when the IR describes at least one method that uses
-- @#[from_auth(...)]@ (i.e. a param with @x-plexus-source.from = "auth"@).
backendRequiresCookieAuth :: Value -> Bool
backendRequiresCookieAuth val = case val of
  Object top -> case KM.lookup "irMethods" top of
    Just (Object ms) -> any hasAuthParam (KM.elems ms)
    _                -> False
  _ -> False
  where
    hasAuthParam :: Value -> Bool
    hasAuthParam (Object m) = case KM.lookup "mdParams" m of
      Just (Array params) -> any paramIsAuth (foldr (:) [] params)
      _                   -> False
    hasAuthParam _ = False

    paramIsAuth :: Value -> Bool
    paramIsAuth (Object p) = case KM.lookup "pdSource" p of
      Just (Object src) -> case KM.lookup "from" src of
        Just (String "auth") -> True
        _                    -> False
      _ -> False
    paramIsAuth _ = False

-- | Inspect the target directory for a SAFE-7-marked transport.ts.
-- Returns a warning when transport.ts exists but lacks the marker.
-- Returns 'Nothing' when transport.ts doesn't exist (first build) or
-- does contain the marker (correctly configured).
inspectTarget :: FilePath -> IO (Maybe Text)
inspectTarget outputDir = do
  let tsFile = outputDir </> "transport.ts"
  exists <- doesFileExist tsFile
  if not exists
    then pure Nothing  -- first build; nothing to compare
    else do
      contents <- TIO.readFile tsFile
      if safe7Marker `T.isInfixOf` contents
        then pure Nothing
        else pure . Just $
          "[!] SAFE-6: backend requires cookie auth but target's transport.ts "
          <> "does not look like a SAFE-7-era hub-codegen output (missing marker '"
          <> safe7Marker
          <> "'). Cookie-based WS upgrade may not work. "
          <> "Regenerate with an up-to-date hub-codegen or pass --force."
