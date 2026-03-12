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
  ) where

import Control.Applicative ((<|>))
import Control.Monad (foldM)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, doesFileExist)

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
