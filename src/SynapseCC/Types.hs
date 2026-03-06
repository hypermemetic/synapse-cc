{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Core types for synapse-cc
module SynapseCC.Types
  ( -- * Version Information
    synapseCCVersion

    -- * Configuration
  , Config(..)
  , Target(..)
  , Backend(..)
  , TransportType(..)
  , Options(..)
  , defaultOptions

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
import Data.Map.Strict (Map)
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
  } deriving stock (Show, Eq, Generic)

-- | Target language for code generation
data Target
  = TypeScript
  | Python
  | Rust
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (FromJSON, ToJSON)

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
  }

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

  SynapseError stderr exitCode ->
    T.unlines
      [ "[!] Error: synapse failed (exit code " <> T.pack (show exitCode) <> ")"
      , ""
      , "Output:"
      , stderr
      ]

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
