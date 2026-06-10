{-# LANGUAGE OverloadedStrings #-}

-- | Project detection layer for synapse-cc init.
--
-- Inspects the current working directory to infer appropriate config values
-- (transport mode, output directory, etc.) so that generated synapse.config.json
-- is correct out of the box for common project structures.
--
-- Detectors are plain values — extend by prepending to the list passed to
-- 'runDetectors'. Earlier detectors win on a per-field basis.
module SynapseCC.Detect
  ( -- * Types
    ProjectHint(..)
  , Detector(..)
  , emptyHint

    -- * Running detectors
  , runDetectors

    -- * Default detector set
  , defaultDetectors

    -- * Individual detectors (for composition and testing)
  , detectTauri
  , detectVite
  , detectNextJS
  , detectNodeProject

    -- * Backend inference (Z2H-5)
  , BackendInference(..)
  , InferenceOutcome(..)
  , inferBackend
  , inferBackendFromCrate
  , inferBackendFromRegistry
  , parseServiceCrateName
  ) where

import Control.Applicative ((<|>))
import Control.Exception (try, SomeException)
import Control.Monad (foldM)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.FilePath ((</>), takeDirectory)

import qualified Synapse.Backend.Discovery as D

import SynapseCC.Types (TransportType(..))

-- ============================================================================
-- Hint type
-- ============================================================================

-- | Inferred preferences for a new synapse.config.json.
-- 'Nothing' means "no opinion" — another detector or the hardcoded default wins.
data ProjectHint = ProjectHint
  { phTransport :: Maybe TransportType
    -- ^ 'WsTransport' (Node.js) or 'BrowserTransport' (native WebSocket)
  , phReason    :: Maybe T.Text
    -- ^ Human-readable explanation of why transport was chosen
  } deriving (Show, Eq)

-- | Hint with no opinions on any field.
emptyHint :: ProjectHint
emptyHint = ProjectHint Nothing Nothing

-- | Merge two hints: earlier/left values win per field.
-- Uses 'Control.Applicative.<|>' which picks the first 'Just'.
mergeHints :: ProjectHint -> ProjectHint -> ProjectHint
mergeHints a b = ProjectHint
  { phTransport = phTransport a <|> phTransport b
  , phReason    = phReason a    <|> phReason b
  }

-- ============================================================================
-- Detector type
-- ============================================================================

-- | A named detector that inspects the project and returns a hint.
--
-- Detectors are run in order; the first non-Nothing value wins per field.
-- Add custom detectors by prepending them to the list passed to 'runDetectors'.
data Detector = Detector
  { detectorName :: T.Text
    -- ^ Short label for debug output (e.g. "tauri", "vite")
  , runDetector  :: IO ProjectHint
    -- ^ IO action: inspect CWD, return hints (or 'emptyHint' if not applicable)
  }

-- ============================================================================
-- Running detectors
-- ============================================================================

-- | Run all detectors in order, merging results.
-- The first non-Nothing value per field wins (leftmost detector takes priority).
runDetectors :: [Detector] -> IO ProjectHint
runDetectors = foldM step emptyHint
  where
    step acc det = mergeHints acc <$> runDetector det

-- ============================================================================
-- Default detector set
-- ============================================================================

-- | Default detector list, in priority order:
--
-- @
-- detectTauri      -- src-tauri/          → browser
-- detectVite       -- vite.config.*       → browser
-- detectNextJS     -- next.config.*       → browser
-- detectNodeProject-- package.json        → ws (fallback)
-- @
--
-- Inject additional detectors by prepending to this list:
--
-- @
-- myDetector : defaultDetectors
-- @
defaultDetectors :: [Detector]
defaultDetectors =
  [ detectTauri
  , detectVite
  , detectNextJS
  , detectNodeProject
  ]

-- ============================================================================
-- Individual detectors
-- ============================================================================

-- | Tauri desktop-app projects.
-- Looks for 'src-tauri/' directory or 'tauri.conf.json' (v1 or v2).
-- Sets transport to 'BrowserTransport' — Tauri's WebView exposes a native
-- 'WebSocket' global, so the @ws@ npm package must not be imported.
detectTauri :: Detector
detectTauri = Detector "tauri" $ do
  hasSrcTauri  <- doesDirectoryExist "src-tauri"
  hasTauriConf <- anyExist
    [ "tauri.conf.json"
    , "src-tauri/tauri.conf.json"
    , "src-tauri/tauri.conf.json5"
    ]
  if hasSrcTauri || hasTauriConf
    then pure emptyHint
      { phTransport = Just BrowserTransport
      , phReason    = Just "Tauri project detected (src-tauri/) — using browser WebSocket"
      }
    else pure emptyHint

-- | Vite projects (browser-native bundler context).
-- Looks for 'vite.config.ts', 'vite.config.js', or 'vite.config.mts'.
-- Sets transport to 'BrowserTransport'.
detectVite :: Detector
detectVite = Detector "vite" $ do
  found <- anyExist
    [ "vite.config.ts"
    , "vite.config.js"
    , "vite.config.mts"
    , "vite.config.mjs"
    ]
  if found
    then pure emptyHint
      { phTransport = Just BrowserTransport
      , phReason    = Just "Vite project detected — using browser WebSocket"
      }
    else pure emptyHint

-- | Next.js projects.
-- Looks for 'next.config.js', 'next.config.ts', or 'next.config.mjs'.
-- Sets transport to 'BrowserTransport' (client components use native WebSocket).
detectNextJS :: Detector
detectNextJS = Detector "nextjs" $ do
  found <- anyExist
    [ "next.config.js"
    , "next.config.ts"
    , "next.config.mjs"
    ]
  if found
    then pure emptyHint
      { phTransport = Just BrowserTransport
      , phReason    = Just "Next.js project detected — using browser WebSocket"
      }
    else pure emptyHint

-- | Bare Node.js projects (package.json present, no framework marker).
-- Sets transport to 'WsTransport' — the @ws@ npm package is available in Node.
-- This is the fallback: runs last, so framework detectors override it.
detectNodeProject :: Detector
detectNodeProject = Detector "node" $ do
  found <- doesFileExist "package.json"
  if found
    then pure emptyHint
      { phTransport = Just WsTransport
      , phReason    = Just "Node.js project detected — using ws WebSocket"
      }
    else pure emptyHint

-- ============================================================================
-- Helpers
-- ============================================================================

-- | Return True if any of the given paths exists as a file.
anyExist :: [FilePath] -> IO Bool
anyExist paths = foldM step False paths
  where
    step True  _    = pure True
    step False path = doesFileExist path

-- ============================================================================
-- Backend inference (Z2H-5)
-- ============================================================================

-- | A successfully inferred backend name plus a human-readable explanation
-- of where it came from. The explanation is ALWAYS surfaced to the user —
-- bare @synapse-cc init@ must never silently pick a backend.
data BackendInference = BackendInference
  { biBackend :: !T.Text  -- ^ Inferred backend identifier
  , biReason  :: !T.Text  -- ^ Why (announced to the user)
  } deriving (Show, Eq)

-- | Outcome of trying to infer a backend when none was given.
data InferenceOutcome
  = Inferred !BackendInference
    -- ^ Exactly one candidate found
  | AmbiguousRegistry ![T.Text]
    -- ^ Registry reachable but lists multiple backends — user must choose
  | NoInference
    -- ^ Nothing inferable (no service crate, registry empty/unreachable)
  deriving (Show, Eq)

-- | Infer the backend for @synapse-cc init@ when no argument was given.
--
-- Sources, in priority order:
--
--  1. A co-located Plexus service crate: a @Cargo.toml@ in the current
--     directory (or its parent) whose package depends on a plexus service
--     crate (@plexus-rpc@, @plexus-core@, or @plexus-transport@). The crate
--     name becomes the backend name.
--  2. The local Plexus registry at the given host:port (default
--     @127.0.0.1:4444@), reusing the existing
--     'Synapse.Backend.Discovery' mechanism — but only when it lists
--     exactly one backend. Multiple backends are ambiguous.
inferBackend
  :: T.Text  -- ^ registry host
  -> Int     -- ^ registry port
  -> IO InferenceOutcome
inferBackend regHost regPort = do
  cwd <- getCurrentDirectory
  fromCrate <- inferBackendFromCrate cwd
  case fromCrate of
    Just bi -> pure (Inferred bi)
    Nothing -> inferBackendFromRegistry regHost regPort

-- | Look for a co-located Plexus service crate: @Cargo.toml@ in the given
-- directory, then in its parent. Returns the crate's package name when the
-- crate looks like a Plexus service (see 'parseServiceCrateName').
inferBackendFromCrate :: FilePath -> IO (Maybe BackendInference)
inferBackendFromCrate dir = go [dir, takeDirectory dir]
  where
    go [] = pure Nothing
    go (d:rest) = do
      let manifest = d </> "Cargo.toml"
      exists <- doesFileExist manifest
      if not exists
        then go rest
        else do
          content <- TIO.readFile manifest
          case parseServiceCrateName content of
            Just name -> pure $ Just BackendInference
              { biBackend = name
              , biReason  = "Inferred backend '" <> name
                         <> "' from co-located Plexus service crate ("
                         <> T.pack manifest <> ")"
              }
            Nothing -> go rest

-- | Extract the package name from Cargo.toml text — but only when the crate
-- depends on a Plexus service crate (@plexus-rpc@, @plexus-core@, or
-- @plexus-transport@). A random Rust crate is NOT a backend.
--
-- This is a line-oriented scan, not a full TOML parser: it understands
-- @[package]@ section @name = "..."@ entries, @[dependencies]@-style section
-- keys, and table-form deps like @[dependencies.plexus-rpc]@.
parseServiceCrateName :: T.Text -> Maybe T.Text
parseServiceCrateName toml =
  let lns = map T.strip (T.lines toml)
      -- Pair each line with its enclosing [section]
      sectioned = go "" lns
        where
          go _ [] = []
          go sec (l:rest)
            | Just hdr <- sectionHeader l = (hdr, l) : go hdr rest
            | otherwise                   = (sec, l) : go sec rest
      sectionHeader l = do
        inner <- T.stripPrefix "[" l
        body  <- T.stripSuffix "]" inner
        pure (T.strip body)
      isDepSection sec =
        sec == "dependencies" || "dependencies." `T.isPrefixOf` sec
        || sec == "workspace.dependencies" || "workspace.dependencies." `T.isPrefixOf` sec
      plexusCrates = ["plexus-rpc", "plexus-core", "plexus-transport"]
      -- A dep either appears as a key in a deps section…
      keyOf l = T.strip (fst (T.breakOn "=" l))
      hasInlineDep = any (\(sec, l) -> isDepSection sec && keyOf l `elem` plexusCrates) sectioned
      -- …or as a table-form section header [dependencies.plexus-rpc]
      hasTableDep = any (\(sec, _) ->
        any (\c -> sec == "dependencies." <> c
                || sec == "workspace.dependencies." <> c) plexusCrates) sectioned
      pkgName = listToMaybe $ mapMaybe
        (\(sec, l) ->
          if sec == "package" && keyOf l == "name"
            then unquote (T.strip (T.drop 1 (snd (T.breakOn "=" l))))
            else Nothing)
        sectioned
      unquote t = T.stripPrefix "\"" =<< T.stripSuffix "\"" t
  in if hasInlineDep || hasTableDep then pkgName else Nothing

-- | Query the local registry for registered backends, reusing the existing
-- 'Synapse.Backend.Discovery' machinery (no new registry protocol — Z2H-6
-- owns registration mechanics). Infers only when EXACTLY one backend is
-- registered; multiple candidates are ambiguous and reported as such.
-- Unreachable or empty registry → 'NoInference' (never an error here —
-- the caller decides how to phrase the failure).
inferBackendFromRegistry :: T.Text -> Int -> IO InferenceOutcome
inferBackendFromRegistry regHost regPort = do
  let discovery = D.registryDiscovery regHost regPort
  result <- try (D.discoverBackends discovery) :: IO (Either SomeException [D.Backend])
  case result of
    Left _        -> pure NoInference
    Right []      -> pure NoInference
    Right [b]     -> pure $ Inferred BackendInference
      { biBackend = D.backendName b
      , biReason  = "Inferred backend '" <> D.backendName b
                 <> "' — the only backend registered on the local registry at "
                 <> regHost <> ":" <> T.pack (show regPort)
      }
    Right many    -> pure $ AmbiguousRegistry (map D.backendName many)
