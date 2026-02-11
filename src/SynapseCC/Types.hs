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

    -- * Errors
  , SynapseCCError(..)
  , formatError
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import System.FilePath (FilePath)

-- ============================================================================
-- Version Information
-- ============================================================================

-- | synapse-cc version (from cabal file: synapse-cc.cabal)
synapseCCVersion :: Text
synapseCCVersion = "0.1.0.0"

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

-- | Options for code generation and compilation
data Options = Options
  { optOutput          :: !FilePath
  , optBundleTransport :: !Bool
  , optInstallDeps     :: !Bool
  , optBuild           :: !Bool
  , optRunTests        :: !Bool
  , optCacheDir        :: !FilePath
  , optForce           :: !Bool
  , optWatch           :: !Bool
  , optDebug           :: !Bool
  } deriving stock (Show, Eq, Generic)

-- | Default options
defaultOptions :: Options
defaultOptions = Options
  { optOutput          = "./generated"
  , optBundleTransport = True
  , optInstallDeps     = True
  , optBuild           = True
  , optRunTests        = False
  , optCacheDir        = "~/.cache/plexus-codegen"
  , optForce           = False
  , optWatch           = False
  , optDebug           = False
  }

-- ============================================================================
-- Tool Locations
-- ============================================================================

-- | Discovered locations of required tools
data ToolLocations = ToolLocations
  { toolSynapse    :: !ToolPath
  , toolHubCodegen :: !ToolPath
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
  , ipcSchemaHash   :: !Text         -- Hash of the source schema (V2 granular)
  , ipcDependencies :: ![Text]       -- List of plugin dependencies
  , ipcCachedAt     :: !Text         -- ISO 8601 timestamp
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Cache entry for a single plugin's generated code
data CodePluginCache = CodePluginCache
  { cpcIRHash    :: !Text            -- Hash of the IR that generated this code
  , cpcCachedAt  :: !Text            -- ISO 8601 timestamp
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

  LanguageToolError tool stderr exitCode ->
    T.unlines
      [ "[!] Error: " <> tool <> " failed (exit code " <> T.pack (show exitCode) <> ")"
      , ""
      , "Output:"
      , stderr
      ]

  CacheError msg ->
    "[!] Cache error: " <> msg

  InvalidIR msg ->
    T.unlines
      [ "[!] Error: Invalid IR"
      , ""
      , msg
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
