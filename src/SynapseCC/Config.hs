{-# LANGUAGE OverloadedStrings #-}

-- | synapse.config.json loader and validator
module SynapseCC.Config
  ( loadSynapseConfig
  , validateSynapseConfig
  , initSynapseConfig
  , synapseConfigPath

    -- * Shared config-to-runtime conversions
  , parseWsUrl
  , buildConfigFromTarget
  ) where

import Data.Aeson (eitherDecodeFileStrict)
import qualified Data.Aeson.Encode.Pretty as Pretty
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist)

import SynapseCC.Detect (Detector, ProjectHint(..), runDetectors)
import SynapseCC.Types

-- | Standard config file name (looked up from CWD)
synapseConfigPath :: FilePath
synapseConfigPath = "synapse.config.json"

-- | Load synapse.config.json from the current directory.
-- Returns Left if the file doesn't exist or fails to parse.
loadSynapseConfig :: IO (Either Text SynapseConfig)
loadSynapseConfig = loadSynapseConfigFrom synapseConfigPath

-- | Load from an explicit path (for hot-reload)
loadSynapseConfigFrom :: FilePath -> IO (Either Text SynapseConfig)
loadSynapseConfigFrom path = do
  exists <- doesFileExist path
  if not exists
    then pure $ Left $ "synapse.config.json not found at " <> T.pack path
                    <> " — run 'synapse-cc init' to create one"
    else do
      result <- eitherDecodeFileStrict path
      case result of
        Left err  -> pure $ Left $ T.pack err
        Right cfg -> case validateSynapseConfig cfg of
          Left verr -> pure $ Left verr
          Right ()  -> pure $ Right cfg

-- | Validate a loaded SynapseConfig, returning the first error found.
validateSynapseConfig :: SynapseConfig -> Either Text ()
validateSynapseConfig cfg = do
  requireNonEmpty "language" (scLanguage cfg)
  -- backend and url are required only when at least one target needs a backend.
  -- A target with generate: ["transport"] is backend-free.
  -- Each non-transport-only target needs a backend from either its own fields or top-level
  let targetsNeedingBackend = filter ((/= ["transport"]) . tcGenerate . snd) (Map.toList (scTargets cfg))
      missingBackend = filter (\(_, tc) ->
        case (tcBackend tc, scBackend cfg) of
          (Nothing, Nothing) -> True
          _                  -> False
        ) targetsNeedingBackend
  case missingBackend of
    ((name, _):_) -> Left $ "target \"" <> name <> "\": no \"backend\" specified (set per-target or top-level)"
    []            -> Right ()
  if Map.null (scTargets cfg)
    then Left "At least one entry under \"targets\" is required"
    else mapM_ (validateTargetConfig (scTargets cfg)) (Map.toList (scTargets cfg))
  where
    requireNonEmpty field val =
      if T.null (T.strip val)
        then Left $ "\"" <> field <> "\" must not be empty"
        else Right ()

validateTargetConfig :: Map Text TargetConfig -> (Text, TargetConfig) -> Either Text ()
validateTargetConfig _all (name, tc) = do
  if null (tcGenerate tc)
    then Left $ "target \"" <> name <> "\": \"generate\" list must not be empty"
    else Right ()
  if null (tcOutputDir tc)
    then Left $ "target \"" <> name <> "\": \"outputDir\" must not be empty"
    else Right ()

-- ============================================================================
-- Config-to-Runtime Conversions
-- ============================================================================

-- | Parse host and port from a ws:// or wss:// URL.
-- Defaults port to "4444" when absent.
parseWsUrl :: Text -> (Text, Text)
parseWsUrl url =
  let stripped = case T.stripPrefix "wss://" url of
        Just s  -> s
        Nothing -> case T.stripPrefix "ws://" url of
          Just s  -> s
          Nothing -> url
      (host, rest) = T.breakOn ":" stripped
      port         = T.takeWhile (/= '/') (T.drop 1 rest)
  in (host, if T.null port then "4444" else port)

-- | Build a runtime Config from a set of CLI options, a SynapseConfig, and one target.
-- The target's outputDir and transport override the options; all other options
-- (--debug, --force, --no-install, etc.) are inherited as-is.
buildConfigFromTarget :: Options -> SynapseConfig -> TargetConfig -> Config
buildConfigFromTarget opts sc tc =
  let url            = fromMaybe (fromMaybe "ws://127.0.0.1:4444" (scUrl sc)) (tcUrl tc)
      (host, port)   = parseWsUrl url
      backendName    = fromMaybe (fromMaybe "" (scBackend sc)) (tcBackend tc)
  in Config
       { cfgTarget  = parseLanguage (scLanguage sc)
       , cfgBackend = Backend backendName
       , cfgHost    = host
       , cfgPort    = port
       , cfgOptions = opts
           { optOutput    = tcOutputDir tc
           , optTransport = tcTransport tc
           }
       , cfgPlugins = tcPlugins tc
       }

-- | Scaffold a synapse.config.json, using 'detectors' to infer the right
-- transport and other settings for the current project.
--
-- Returns @Left@ if the file already exists.
-- Returns @Right hint@ on success — the caller can inspect 'phReason' to
-- print a message explaining what was detected.
--
-- Pass 'SynapseCC.Detect.defaultDetectors' for the standard set, or prepend
-- additional detectors for project-specific overrides.
initSynapseConfig :: FilePath -> [Detector] -> IO (Either Text ProjectHint)
initSynapseConfig path detectors = do
  exists <- doesFileExist path
  if exists
    then pure $ Left $ T.pack path <> " already exists"
    else do
      hint <- runDetectors detectors
      let config = applyHint hint defaultSynapseConfig
      BL.writeFile path (Pretty.encodePretty' prettyConfig config)
      pure $ Right hint

-- | Apply detected hints to the default config.
applyHint :: ProjectHint -> SynapseConfig -> SynapseConfig
applyHint hint cfg =
  case phTransport hint of
    Nothing -> cfg
    Just t  -> cfg
      { scTargets = Map.map (\tc -> tc { tcTransport = t }) (scTargets cfg)
      }

-- | aeson-pretty config: 2-space indent, semantic field ordering.
prettyConfig :: Pretty.Config
prettyConfig = Pretty.defConfig
  { Pretty.confCompare = Pretty.keyOrder
      [ "schema", "language", "backend", "url", "packageManager"
      , "watch", "pollInterval", "hotReload"
      , "targets", "generate", "transport", "outputDir", "smokePath"
      ]
  }
