{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Core types for synapse-cc
module SynapseCC.Types
  ( -- * Version Information
    synapseCCVersion

    -- * Configuration
  , Config(..)
  , Target(..)
  , targetToText
  , parseLanguage
  , Backend(..)
  , TransportType(..)
  , Options(..)
  , defaultOptions

    -- * Synapse Config File
  , SynapseConfig(..)
  , TargetConfig(..)
  , WatchConfig(..)
  , defaultSynapseConfig
  , defaultWatchConfig

    -- * Commands (CLI subcommands)
  , Command(..)
  , WatchArgs(..)
  , WaitArgs(..)

    -- * Tool Locations
  , ToolLocations(..)
  , ToolPath(..)

    -- * Pipeline Results
  , IRPath(..)
  , GeneratedPath(..)
  , CompiledPath(..)

    -- * Cache Types
  , ToolchainVersions(..)
  , IRPluginCache(..)
  , CodePluginCache(..)
  , IRCacheManifest(..)
  , CodeCacheManifest(..)
  , CacheResult(..)
  , CacheMissReason(..)

    -- * Codegen Output
  , CodegenOutput(..)
  , CodegenWarning(..)

    -- * Errors
  , SynapseCCError(..)
  , formatError
  , summarizeStderr
  ) where

import Data.Aeson (FromJSON, ToJSON, fieldLabelModifier)
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Version (showVersion)
import GHC.Generics (Generic)
import Paths_synapse_cc (version)
import System.FilePath (FilePath)

-- ============================================================================
-- Version Information
-- ============================================================================

-- | synapse-cc version (from cabal file: synapse-cc.cabal)
synapseCCVersion :: Text
synapseCCVersion = T.pack (showVersion version)

-- ============================================================================
-- Configuration
-- ============================================================================

-- | Main configuration for synapse-cc
data Config = Config
  { cfgTarget         :: !Target
  , cfgBackend        :: !Backend
  , cfgHost           :: !Text
  , cfgPort           :: !Text
  , cfgOptions        :: !Options
  , cfgPlugins        :: !(Maybe [Text])  -- ^ Plugin filter (Nothing = all)
  } deriving stock (Show, Eq, Generic)

-- | Target language for code generation
data Target
  = TypeScript
  | Python
  | Rust
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Canonical Target → lowercase string (used in cache paths, manifest fields, etc.)
targetToText :: Target -> Text
targetToText TypeScript = "typescript"
targetToText Python     = "python"
targetToText Rust       = "rust"

-- | Parse a language string from synapse.config.json into a Target.
-- Unrecognised values default to TypeScript.
parseLanguage :: Text -> Target
parseLanguage "typescript" = TypeScript
parseLanguage "python"     = Python
parseLanguage "rust"       = Rust
parseLanguage _            = TypeScript

-- | Backend identifier
data Backend = Backend
  { backendName :: !Text  -- ^ Backend name (e.g., "substrate", "plexus")
  } deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Transport environment for generated TypeScript code
data TransportType = WsTransport | BrowserTransport
  deriving stock (Show, Eq, Generic)

-- | Options for code generation and compilation
data Options = Options
  { optOutput          :: !FilePath
  , optTransport       :: !TransportType
  , optInstallDeps     :: !Bool
  , optBuild           :: !Bool
  , optRunTests        :: !Bool
  , optCacheDir        :: !FilePath
  , optForce           :: !Bool
  , optDebug           :: !Bool
  , optSynapsePath     :: !(Maybe FilePath)  -- ^ Override synapse binary path
  , optHubCodegenPath  :: !(Maybe FilePath)  -- ^ Override hub-codegen binary path
  , optToken           :: !(Maybe Text)      -- ^ JWT token (--token; SAFE-2)
  , optTokenFile       :: !(Maybe FilePath)  -- ^ Token file path (--token-file; SAFE-2)
  } deriving stock (Show, Eq, Generic)

-- | Default options
defaultOptions :: Options
defaultOptions = Options
  { optOutput          = "./generated"
  , optTransport       = WsTransport
  , optInstallDeps     = True
  , optBuild           = True
  , optRunTests        = False
  , optCacheDir        = "~/.cache/plexus-codegen"
  , optForce           = False
  , optDebug           = False
  , optSynapsePath     = Nothing
  , optHubCodegenPath  = Nothing
  , optToken           = Nothing
  , optTokenFile       = Nothing
  }

-- ============================================================================
-- Synapse Config File (synapse.config.json)
-- ============================================================================

-- | Watch-mode configuration
data WatchConfig = WatchConfig
  { wcPollInterval :: !Int   -- ^ Milliseconds between hash polls (default: 1000)
  , wcHotReload    :: !Bool  -- ^ Reload config on file change if valid (default: False)
  } deriving stock (Show, Eq, Generic)

instance FromJSON WatchConfig where
  parseJSON = Aeson.withObject "WatchConfig" $ \o -> WatchConfig
    <$> o Aeson..:? "pollInterval" Aeson..!= 1000
    <*> o Aeson..:? "hotReload"    Aeson..!= False

instance ToJSON WatchConfig where
  toJSON wc = Aeson.object
    [ "pollInterval" Aeson..= wcPollInterval wc
    , "hotReload"    Aeson..= wcHotReload wc
    ]

defaultWatchConfig :: WatchConfig
defaultWatchConfig = WatchConfig
  { wcPollInterval = 1000
  , wcHotReload    = False
  }

-- | Per-target configuration entry in synapse.config.json
data TargetConfig = TargetConfig
  { tcGenerate        :: ![Text]           -- ^ Selectors: ["transport","rpc","plugins"] or ["all"]
  , tcTransport       :: !TransportType    -- ^ Transport for this target
  , tcOutputDir       :: !FilePath         -- ^ Where to write generated files
  , tcSmokePath       :: !(Maybe Text)     -- ^ Relative path to transport for smoke targets
  , tcBackend         :: !(Maybe Text)     -- ^ Per-target backend override
  , tcUrl             :: !(Maybe Text)     -- ^ Per-target WebSocket URL override
  , tcPlugins         :: !(Maybe [Text])   -- ^ Plugin filter (Nothing = all)
  , tcSharedTransport :: !(Maybe Text)     -- ^ Name of another target whose transport to reuse
  } deriving stock (Show, Eq, Generic)

instance FromJSON TargetConfig where
  parseJSON = Aeson.withObject "TargetConfig" $ \o -> TargetConfig
    <$> o Aeson..: "generate"
    <*> (parseTransport =<< o Aeson..: "transport")
    <*> o Aeson..: "outputDir"
    <*> o Aeson..:? "smokePath"
    <*> o Aeson..:? "backend"
    <*> o Aeson..:? "url"
    <*> o Aeson..:? "plugins"
    <*> o Aeson..:? "sharedTransport"
    where
      parseTransport :: Text -> Parser TransportType
      parseTransport "ws"      = pure WsTransport
      parseTransport "browser" = pure BrowserTransport
      parseTransport t         = fail $ "Unknown transport: " <> show t

instance ToJSON TargetConfig where
  toJSON tc = Aeson.object $
    [ "generate"  Aeson..= tcGenerate tc
    , "transport" Aeson..= (case tcTransport tc of WsTransport -> "ws" :: Text; BrowserTransport -> "browser")
    , "outputDir" Aeson..= tcOutputDir tc
    ] ++ case tcSmokePath tc of
           Nothing -> []
           Just p  -> ["smokePath" Aeson..= p]
      ++ case tcBackend tc of
           Nothing -> []
           Just b  -> ["backend" Aeson..= b]
      ++ case tcUrl tc of
           Nothing -> []
           Just u  -> ["url" Aeson..= u]
      ++ case tcPlugins tc of
           Nothing -> []
           Just ps -> ["plugins" Aeson..= ps]
      ++ case tcSharedTransport tc of
           Nothing -> []
           Just st -> ["sharedTransport" Aeson..= st]

-- | Top-level synapse.config.json configuration.
-- \"backend\" and \"url\" are optional when every target has generate: [\"transport\"]
-- (transport.ts is a static template that needs no backend connection).
data SynapseConfig = SynapseConfig
  { scSchema         :: !Text                -- ^ Config schema version (e.g. "1.0")
  , scLanguage       :: !Text                -- ^ Target language (e.g. "typescript")
  , scBackend        :: !(Maybe Text)        -- ^ Backend identifier; omit for transport-only configs
  , scUrl            :: !(Maybe Text)        -- ^ Backend WebSocket URL; omit for transport-only configs
  , scPackageManager :: !Text                -- ^ Package manager (e.g. "bun")
  , scWatch          :: !WatchConfig         -- ^ Watch mode settings
  , scTargets        :: !(Map Text TargetConfig)  -- ^ Named build targets
  } deriving stock (Show, Eq, Generic)

instance FromJSON SynapseConfig where
  parseJSON = Aeson.withObject "SynapseConfig" $ \o -> SynapseConfig
    <$> o Aeson..: "schema"
    <*> o Aeson..: "language"
    <*> o Aeson..:? "backend"
    <*> o Aeson..:? "url"
    <*> o Aeson..:? "packageManager" Aeson..!= "bun"
    <*> o Aeson..:? "watch"          Aeson..!= defaultWatchConfig
    <*> o Aeson..: "targets"

instance ToJSON SynapseConfig where
  toJSON sc = Aeson.object $ catMaybes
    [ Just $ "schema"         Aeson..= scSchema sc
    , Just $ "language"       Aeson..= scLanguage sc
    , ("backend" Aeson..=) <$> scBackend sc
    , ("url"     Aeson..=) <$> scUrl sc
    , Just $ "packageManager" Aeson..= scPackageManager sc
    , Just $ "watch"          Aeson..= scWatch sc
    , Just $ "targets"        Aeson..= scTargets sc
    ]

defaultSynapseConfig :: SynapseConfig
defaultSynapseConfig = SynapseConfig
  { scSchema         = "1.0"
  , scLanguage       = "typescript"
  , scBackend        = Just "substrate"
  , scUrl            = Just "ws://127.0.0.1:4444"
  , scPackageManager = "bun"
  , scWatch          = defaultWatchConfig
  , scTargets        = Map.fromList
      [ ( "client"
        , TargetConfig
            { tcGenerate        = ["transport", "rpc", "plugins"]
            , tcTransport       = WsTransport
            , tcOutputDir       = "src/lib/plexus"
            , tcSmokePath       = Nothing
            , tcBackend         = Nothing
            , tcUrl             = Nothing
            , tcPlugins         = Nothing
            , tcSharedTransport = Nothing
            }
        )
      ]
  }

-- ============================================================================
-- Commands (CLI Subcommands)
-- ============================================================================

-- | Top-level CLI command
data Command
  = CmdBuild Config         -- ^ Build with explicit target/backend (CLI args)
  | CmdBuildFromConfig      -- ^ Build all targets from synapse.config.json
      Options               -- ^ CLI flags that override per-target config
  | CmdWatch WatchArgs      -- ^ Watch mode
  | CmdWait WaitArgs        -- ^ Wait for backends to become reachable
  | CmdInit                 -- ^ Scaffold synapse.config.json
  deriving stock (Show, Eq)

-- | Arguments for the watch subcommand
data WatchArgs = WatchArgs
  { waBackend   :: !Text         -- ^ Backend identifier (e.g. "substrate")
  , waPlugins   :: ![Text]       -- ^ Plugin prefix filters (empty = all)
  , waTarget    :: !(Maybe Text) -- ^ Pin to a single named config target
  , waInterval  :: !(Maybe Int)  -- ^ Poll interval override in ms (overrides config)
  , waOptions   :: !Options      -- ^ Inherited options (host, port, cache, debug, etc.)
  } deriving stock (Show, Eq)

-- | Arguments for the wait subcommand
data WaitArgs = WaitArgs
  { waitBackend  :: !(Maybe Text)  -- ^ Specific backend (if None, use all from config)
  , waitUrl      :: !(Maybe Text)  -- ^ Explicit URL (requires backend)
  , waitTimeout  :: !Int           -- ^ Max seconds to wait (default 30)
  , waitInterval :: !Int           -- ^ Poll interval in ms (default 500)
  , waitDebug    :: !Bool          -- ^ Debug logging
  } deriving stock (Show, Eq)

-- ============================================================================
-- Tool Locations
-- ============================================================================

-- | Discovered locations of required tools
data ToolLocations = ToolLocations
  { toolSynapse            :: !ToolPath
  , toolHubCodegen         :: !ToolPath
  , toolSynapseVersion     :: !Text   -- ^ Result of @synapse --version@
  , toolHubCodegenVersion  :: !Text   -- ^ Result of @hub-codegen --version@
  } deriving stock (Show, Eq)

-- | Path to a discovered tool
data ToolPath
  = LocalDev !FilePath    -- ^ Local development build
  | SystemPath !FilePath  -- ^ Found in $PATH
  | PlexusBin !FilePath   -- ^ Installed in ~/.plexus/bin
  deriving stock (Show, Eq)

-- ============================================================================
-- Pipeline Results
-- ============================================================================

-- | Path to generated IR JSON file
newtype IRPath = IRPath { unIRPath :: FilePath }
  deriving stock (Show, Eq)

-- | Path to generated code directory
newtype GeneratedPath = GeneratedPath { unGeneratedPath :: FilePath }
  deriving stock (Show, Eq)

-- | Path to compiled output
newtype CompiledPath = CompiledPath { unCompiledPath :: FilePath }
  deriving stock (Show, Eq)

-- ============================================================================
-- Cache Types
-- ============================================================================

-- | Toolchain version information for cache invalidation
data ToolchainVersions = ToolchainVersions
  { tvSynapseCC   :: !Text
  , tvSynapse     :: !Text
  , tvHubCodegen  :: !(Maybe Text)  -- Only known after codegen
  , tvPlexusCore  :: !(Maybe Text)  -- SAFE-4: backend-reported plexus-core version (Nothing until SAFE-S02)
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Cache entry for a single plugin's IR
data IRPluginCache = IRPluginCache
  { ipcIRHash       :: !Text         -- Hash of the generated IR for this plugin
  , ipcSchemaHash   :: !Text         -- Hash of the source schema (composite, backward compatible)
  , ipcSelfHash     :: !Text         -- V2: Methods-only hash (for granular invalidation)
  , ipcChildrenHash :: !Text         -- V2: Children-only hash (for granular invalidation)
  , ipcDependencies :: ![Text]       -- List of plugin dependencies
  , ipcCachedAt     :: !Text         -- ISO 8601 timestamp
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Cache entry for a single plugin's generated code
data CodePluginCache = CodePluginCache
  { cpcIRHash      :: !Text            -- Hash of the IR that generated this code
  , cpcFileHashes  :: !(Map Text Text) -- Per-file content hashes (path -> hash)
  , cpcCachedAt    :: !Text            -- ISO 8601 timestamp
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Cache manifest for IR (synapse/ir/manifest.json)
data IRCacheManifest = IRCacheManifest
  { ircmVersion    :: !Text
  , ircmIRVersion  :: !Text
  , ircmToolchain  :: !ToolchainVersions
  , ircmUpdatedAt  :: !Text
  , ircmPlugins    :: !(Map Text IRPluginCache)
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Cache manifest for generated code (hub-codegen/typescript/manifest.json)
data CodeCacheManifest = CodeCacheManifest
  { ccmVersion    :: !Text
  , ccmTarget     :: !Text
  , ccmToolchain  :: !ToolchainVersions
  , ccmUpdatedAt  :: !Text
  , ccmPlugins    :: !(Map Text CodePluginCache)
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Reason for cache miss
data CacheMissReason
  = ToolVersionChanged      -- Tool versions don't match
  | SchemaHashChanged       -- Source schema changed
  | IRHashChanged           -- IR changed
  | DependencyInvalidated   -- Transitive dependency changed
  | ManifestNotFound        -- No cache manifest exists
  | ManifestCorrupted       -- Manifest exists but is invalid
  deriving stock (Show, Eq)

-- | Result of cache validation
data CacheResult
  = FullCacheHit
    -- ^ All plugins are cached and valid
  | PartialCacheHit ![Text] ![Text]
    -- ^ Some plugins valid (first list), some invalid (second list)
  | CacheMiss !CacheMissReason
    -- ^ Cache invalid, must regenerate everything
  deriving stock (Show, Eq)

-- ============================================================================
-- Codegen Output Types (JSON response from hub-codegen --output-format json)
-- ============================================================================

-- | JSON output from hub-codegen when invoked with --output-format json
data CodegenOutput = CodegenOutput
  { coFiles             :: !(Map Text Text)   -- ^ Generated file contents (relPath -> content)
  , coFileHashes        :: !(Map Text Text)   -- ^ Per-file content hashes (relPath -> hash)
  , coWarnings          :: ![CodegenWarning]  -- ^ Warnings from generation
  , coHubCodegenVersion :: !Text             -- ^ hub-codegen version string
  , coDependencies      :: !(Map Text Text)   -- ^ Runtime dependencies (name -> version)
  , coDevDependencies   :: !(Map Text Text)   -- ^ Dev dependencies (name -> version)
  } deriving stock (Show, Eq, Generic)

instance FromJSON CodegenOutput where
  parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
    { fieldLabelModifier = \case
        "coFiles"             -> "files"
        "coFileHashes"        -> "fileHashes"
        "coWarnings"          -> "warnings"
        "coHubCodegenVersion" -> "hubCodegenVersion"
        "coDependencies"      -> "dependencies"
        "coDevDependencies"   -> "devDependencies"
        other -> other
    }

-- | A warning emitted during code generation
data CodegenWarning = CodegenWarning
  { cwLocation :: !Text
  , cwMessage  :: !Text
  } deriving stock (Show, Eq, Generic)

instance FromJSON CodegenWarning where
  parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
    { fieldLabelModifier = \case
        "cwLocation" -> "location"
        "cwMessage"  -> "message"
        other -> other
    }

-- ============================================================================
-- Errors
-- ============================================================================

-- | All possible errors in synapse-cc
data SynapseCCError
  = ToolNotFound !Text ![Text]
    -- ^ Tool not found with suggestions
  | SynapseError !Text !Int
    -- ^ Synapse execution failed with stderr and exit code
  | HubCodegenError !Text !Int
    -- ^ hub-codegen execution failed with stderr and exit code
  | LanguageToolError !Text !Text !Int
    -- ^ Language tool (npm, tsc, etc.) failed
  | CacheError !Text
    -- ^ Cache operation failed
  | InvalidIR !Text
    -- ^ IR parsing failed
  | BackendUnreachable !Text !Text
    -- ^ Cannot connect to backend
  | ConfigError !Text
    -- ^ Invalid configuration
  deriving stock (Show, Eq)

-- | Extract the first meaningful non-empty line from stderr output.
-- Filters out Node.js stack frames and internal paths.
-- Falls back to the first non-empty line if nothing more useful is found.
-- Trims to 120 chars if very long.
summarizeStderr :: Text -> Text
summarizeStderr stderr =
  let ls = T.lines stderr
      isUseful l =
        not (T.null (T.strip l)) &&
        not ("    at " `T.isPrefixOf` l) &&
        not ("at " `T.isPrefixOf` T.strip l) &&
        not ("node:internal" `T.isInfixOf` l) &&
        not ("node_modules" `T.isInfixOf` l)
      firstUseful = case filter isUseful ls of
        (x:_) -> T.take 120 (T.strip x)
        []    -> case filter (not . T.null . T.strip) ls of
          (x:_) -> T.take 120 (T.strip x)
          []    -> "(no output)"
  in firstUseful

-- | Extract the key part of an aeson parse error, stripping the path prefix.
-- E.g. "Error in $['irPlugins']: key \"foo\" not found"
--   -> "key \"foo\" not found"
summarizeAesonError :: Text -> Text
summarizeAesonError msg =
  -- aeson errors look like "Error in $...path...: actual message"
  let afterColon = case T.breakOn ": " msg of
        (_, rest) | not (T.null rest) -> T.drop 2 rest
        _                             -> msg
  in T.take 120 afterColon

-- | Format error for display to user
formatError :: SynapseCCError -> Text
formatError = \case
  ToolNotFound tool suggestions ->
    T.unlines $
      [ "[!] Error: " <> tool <> " not found"
      , ""
      , tool <> " is required by synapse-cc."
      , ""
      , "Try:"
      ] ++ map ("  - " <>) suggestions ++
      [ ""
      , "For more info: https://github.com/hypermemetic/synapse-cc"
      ]

  SynapseError msg _ ->
    "[!] Error: " <> msg <> "\n"

  HubCodegenError stderr exitCode ->
    T.unlines
      [ "[!] Error: hub-codegen failed (exit code " <> T.pack (show exitCode) <> ")"
      , ""
      , "Output:"
      , stderr
      ]

  LanguageToolError tool output exitCode ->
    T.unlines
      [ "[!] Error: " <> tool <> " failed (exit code " <> T.pack (show exitCode) <> ")"
      , ""
      , output
      ]

  CacheError msg ->
    "[!] Cache error: " <> msg

  InvalidIR msg ->
    T.unlines
      [ "[!] Failed to parse IR output from synapse"
      , ""
      , "  The IR JSON was not in the expected format."
      , "  This usually means synapse and synapse-cc are out of sync."
      , ""
      , "  Detail: " <> summarizeAesonError msg
      , ""
      , "  Try: rebuild synapse from source, or check synapse --version"
      ]

  BackendUnreachable url msg ->
    T.unlines
      [ "[!] Error: Cannot connect to backend"
      , ""
      , "URL: " <> url
      , "Reason: " <> msg
      , ""
      , "Is the backend running?"
      ]

  ConfigError msg ->
    "[!] Configuration error: " <> msg
