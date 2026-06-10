{-# LANGUAGE OverloadedStrings #-}

-- | synapse.config.json loader and validator
module SynapseCC.Config
  ( loadSynapseConfig
  , validateSynapseConfig
  , initSynapseConfig
  , InitResult(..)
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

import SynapseCC.Detect
  ( Detector, ProjectHint(..), runDetectors
  , BackendInference(..), InferenceOutcome(..), inferBackend
  )
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
validateTargetConfig allTargets (name, tc) = do
  if null (tcGenerate tc)
    then Left $ "target \"" <> name <> "\": \"generate\" list must not be empty"
    else Right ()
  if null (tcOutputDir tc)
    then Left $ "target \"" <> name <> "\": \"outputDir\" must not be empty"
    else Right ()
  -- Validate sharedTransport references
  case tcSharedTransport tc of
    Nothing -> Right ()
    Just ref -> do
      -- 1. Referenced target must exist
      case Map.lookup ref allTargets of
        Nothing -> Left $ "target \"" <> name <> "\": sharedTransport references unknown target \"" <> ref <> "\""
        Just provider -> do
          -- 2. Provider must have "transport" in its generate list
          if "transport" `notElem` tcGenerate provider && tcGenerate provider /= ["all"]
            then Left $ "target \"" <> name <> "\": sharedTransport target \"" <> ref
                      <> "\" does not generate transport"
            else Right ()
          -- 3. Both targets must use the same transport mode
          if tcTransport tc /= tcTransport provider
            then Left $ "target \"" <> name <> "\": transport mode differs from sharedTransport target \"" <> ref <> "\""
            else Right ()
          -- 4. Consumer must NOT include "transport" or "rpc" in its generate list
          if "transport" `elem` tcGenerate tc || "rpc" `elem` tcGenerate tc
            then Left $ "target \"" <> name
                      <> "\": generate must not include \"transport\" or \"rpc\" when using sharedTransport"
            else Right ()
          -- 5. No circular references
          case tcSharedTransport provider of
            Just _ -> Left $ "target \"" <> name <> "\": sharedTransport chain detected (\"" <> ref
                           <> "\" also uses sharedTransport)"
            Nothing -> Right ()

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

-- | Result of a successful @synapse-cc init@.
data InitResult = InitResult
  { irHint        :: !ProjectHint   -- ^ Transport detection result ('phReason' explains)
  , irBackend     :: !Text          -- ^ Backend name written into the config
  , irBackendNote :: !(Maybe Text)  -- ^ Announcement when the backend was INFERRED
                                    --   (Nothing when given explicitly)
  } deriving (Show, Eq)

-- | Scaffold a synapse.config.json, using 'detectors' to infer the right
-- transport and other settings for the current project.
--
-- Z2H-5: the backend name is either given explicitly (@Just backend@) or
-- inferred via 'inferBackend' (co-located service crate, then local
-- registry at @regHost:regPort@). There is no hardcoded fallback — when
-- nothing is inferable the result is a @Left@ naming the missing argument.
--
-- Returns @Left@ if the file already exists or no backend could be
-- determined. Returns @Right InitResult@ on success — 'irBackendNote'
-- carries the inference announcement the caller MUST surface.
--
-- Pass 'SynapseCC.Detect.defaultDetectors' for the standard set, or prepend
-- additional detectors for project-specific overrides.
initSynapseConfig
  :: FilePath      -- ^ Config path (usually 'synapseConfigPath')
  -> [Detector]    -- ^ Transport detectors
  -> Maybe Text    -- ^ Explicit backend name (Nothing = infer)
  -> Text          -- ^ Registry host for inference (default "127.0.0.1")
  -> Int           -- ^ Registry port for inference (default 4444)
  -> IO (Either Text InitResult)
initSynapseConfig path detectors mBackend regHost regPort = do
  exists <- doesFileExist path
  if exists
    then pure $ Left $ T.pack path <> " already exists"
    else do
      backendResult <- case mBackend of
        Just b  -> pure $ Right (b, Nothing)
        Nothing -> do
          outcome <- inferBackend regHost regPort
          pure $ case outcome of
            Inferred bi -> Right (biBackend bi, Just (biReason bi))
            AmbiguousRegistry known -> Left $
              "missing BACKEND argument — multiple backends are registered ("
              <> T.intercalate ", " known
              <> "). Pick one: synapse-cc init <backend>"
            NoInference -> Left $
              "missing BACKEND argument — no co-located Plexus service crate found"
              <> " and no backend discoverable on the registry at "
              <> regHost <> ":" <> T.pack (show regPort)
              <> ". Run: synapse-cc init <backend>"
      case backendResult of
        Left err -> pure $ Left err
        Right (backend, note) -> do
          hint <- runDetectors detectors
          let config = applyHint hint (defaultSynapseConfig backend)
          BL.writeFile path (Pretty.encodePretty' prettyConfig config)
          pure $ Right InitResult
            { irHint        = hint
            , irBackend     = backend
            , irBackendNote = note
            }

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
      , "targets", "generate", "transport", "outputDir", "smokePath", "sharedTransport"
      ]
  }
