-- | Command-line interface parsing
module SynapseCC.CLI
  ( -- * Legacy build-only parser (for tests)
    parseArgs
  , synapseCCParserInfo

    -- * Command parser (with subcommands)
  , parseCommand
  , synapseCCCommandParserInfo

    -- * Version
  , versionInfo
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative

import SynapseCC.Types

-- ============================================================================
-- Legacy Build Parser (backward-compatible, used by tests)
-- ============================================================================

-- | Full parser info (usable with execParserPure for in-process testing)
synapseCCParserInfo :: ParserInfo Config
synapseCCParserInfo = info (configParser <**> helper <**> simpleVersioner (T.unpack versionInfo))
  ( fullDesc
 <> progDesc "Unified compiler toolchain for Plexus backends"
 <> header "synapse-cc - from schema to compiled client in one command"
  )

-- | Parse command-line arguments into Config (legacy build-only)
parseArgs :: IO Config
parseArgs = execParser synapseCCParserInfo

-- | Main config parser
configParser :: Parser Config
configParser = Config
  <$> targetParser
  <*> backendParser
  <*> hostParser
  <*> portParser
  <*> optionsParser

-- ============================================================================
-- Command Parser (with subcommands: build, watch, init)
-- ============================================================================

-- | Full command parser info with subcommands
synapseCCCommandParserInfo :: ParserInfo Command
synapseCCCommandParserInfo = info (commandParser <**> helper <**> simpleVersioner (T.unpack versionInfo))
  ( fullDesc
 <> progDesc "Unified compiler toolchain for Plexus backends"
 <> header "synapse-cc - from schema to compiled client in one command"
  )

-- | Parse a top-level Command
parseCommand :: IO Command
parseCommand = execParser synapseCCCommandParserInfo

commandParser :: Parser Command
commandParser = subparser
  ( command "build" (info buildCommandParser
      (progDesc "Build client from backend schema (default)"))
 <> command "watch" (info watchCommandParser
      (progDesc "Watch backend for changes and incrementally rebuild"))
 <> command "init"  (info initCommandParser
      (progDesc "Scaffold a synapse.config.json in the current directory"))
  )

buildCommandParser :: Parser Command
buildCommandParser = mkCmd
  <$> optional targetParser
  <*> optional backendParser
  <*> hostParser
  <*> portParser
  <*> optionsParser
  where
    mkCmd (Just t) (Just b) host port opts = CmdBuild (Config t b host port opts)
    mkCmd _        _        _    _    opts = CmdBuildFromConfig opts

watchCommandParser :: Parser Command
watchCommandParser = fmap CmdWatch $ WatchArgs
  <$> (T.pack <$> argument str
        ( metavar "BACKEND"
       <> help "Backend identifier (substrate, plexus, etc.)"
        ))
  <*> many (T.pack <$> argument str
        ( metavar "PLUGIN..."
       <> help "Plugin prefix filters (e.g. echo health). Empty = all plugins."
        ))
  <*> optional (T.pack <$> option str
        ( long "target"
       <> short 't'
       <> metavar "NAME"
       <> help "Pin to a single named target from synapse.config.json"
        ))
  <*> optional (option auto
        ( long "interval"
       <> short 'i'
       <> metavar "MS"
       <> help "Poll interval in milliseconds (overrides synapse.config.json)"
        ))
  <*> watchOptionsParser

initCommandParser :: Parser Command
initCommandParser = pure CmdInit

-- | Options relevant to watch mode.
-- host/port come from synapse.config.json (not CLI flags for watch).
watchOptionsParser :: Parser Options
watchOptionsParser = (\cacheDir debug synapse hub ->
  defaultOptions
    { optInstallDeps    = False
    , optBuild          = False
    , optRunTests       = False
    , optCacheDir       = cacheDir
    , optDebug          = debug
    , optSynapsePath    = synapse
    , optHubCodegenPath = hub
    })
  <$> option str
      ( long "cache-dir"
     <> metavar "DIR"
     <> value (optCacheDir defaultOptions)
     <> showDefault
     <> help "Cache directory"
      )
  <*> switch (long "debug" <> help "Enable debug logging")
  <*> optional (option str (long "synapse"     <> metavar "PATH" <> help "synapse binary path"))
  <*> optional (option str (long "hub-codegen" <> metavar "PATH" <> help "hub-codegen binary path"))

-- ============================================================================
-- Shared Parsers
-- ============================================================================

-- | Parse target language
targetParser :: Parser Target
targetParser = argument readTarget
  ( metavar "TARGET"
 <> help "Target language (typescript, python, rust)"
  )
  where
    readTarget = maybeReader $ \case
      "typescript" -> Just TypeScript
      "ts"         -> Just TypeScript
      "python"     -> Just Python
      "py"         -> Just Python
      "rust"       -> Just Rust
      "rs"         -> Just Rust
      _            -> Nothing

-- | Parse backend name
backendParser :: Parser Backend
backendParser = Backend . T.pack <$> argument str
  ( metavar "BACKEND"
 <> help "Backend identifier (substrate, plexus, synapse, etc.)"
  )

-- | Parse registry host
hostParser :: Parser Text
hostParser = T.pack <$> option str
  ( long "host"
 <> short 'H'
 <> metavar "HOST"
 <> value "127.0.0.1"
 <> showDefault
 <> help "Registry/discovery host"
  )

-- | Parse registry port
portParser :: Parser Text
portParser = T.pack <$> option str
  ( long "port"
 <> short 'P'
 <> metavar "PORT"
 <> value "4444"
 <> showDefault
 <> help "Registry/discovery port"
  )

parseTransport :: String -> Either String TransportType
parseTransport "ws"      = Right WsTransport
parseTransport "browser" = Right BrowserTransport
parseTransport s         = Left $ "Unknown transport: " <> s

-- | Parse options
optionsParser :: Parser Options
optionsParser = Options
  <$> option str
      ( long "output"
     <> short 'o'
     <> metavar "DIR"
     <> value (optOutput defaultOptions)
     <> showDefault
     <> help "Output directory"
      )
  <*> option (eitherReader parseTransport)
      ( long "transport"
     <> metavar "ws|browser"
     <> value WsTransport
     <> help "Transport: ws (Node.js, default) or browser (native WebSocket, for Tauri/WebView)"
      )
  <*> flag True False
      ( long "no-install"
     <> help "Skip dependency installation"
      )
  <*> flag True False
      ( long "no-build"
     <> help "Skip compilation step"
      )
  <*> flag True False
      ( long "no-tests"
     <> help "Skip running smoke tests"
      )
  <*> option str
      ( long "cache-dir"
     <> metavar "DIR"
     <> value (optCacheDir defaultOptions)
     <> showDefault
     <> help "Cache directory"
      )
  <*> switch
      ( long "force"
     <> help "Force regeneration (ignore cache)"
      )
  <*> switch
      ( long "debug"
     <> help "Enable debug logging"
      )
  <*> optional (option str
      ( long "synapse"
     <> metavar "PATH"
     <> help "Path to synapse binary (overrides discovery)"
      ))
  <*> optional (option str
      ( long "hub-codegen"
     <> metavar "PATH"
     <> help "Path to hub-codegen binary (overrides discovery)"
      ))

-- ============================================================================
-- Version Info
-- ============================================================================

-- | Version information
versionInfo :: Text
versionInfo = "synapse-cc v" <> synapseCCVersion
