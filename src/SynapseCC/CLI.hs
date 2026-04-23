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
  <*> pure Nothing

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
 <> command "wait"  (info waitCommandParser
      (progDesc "Block until all configured backends are reachable"))
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
    mkCmd (Just t) (Just b) host port opts = CmdBuild (Config t b host port opts Nothing)
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

waitCommandParser :: Parser Command
waitCommandParser = fmap CmdWait $ WaitArgs
  <$> optional (T.pack <$> argument str
        ( metavar "BACKEND"
       <> help "Backend to wait for (omit to wait for all from config)"
        ))
  <*> optional (T.pack <$> option str
        ( long "url"
       <> short 'u'
       <> metavar "URL"
       <> help "WebSocket URL (e.g. ws://127.0.0.1:4448). Requires BACKEND arg."
        ))
  <*> option auto
        ( long "timeout"
       <> short 't'
       <> metavar "SECONDS"
       <> value 30
       <> showDefault
       <> help "Max seconds to wait before giving up"
        )
  <*> option auto
        ( long "interval"
       <> short 'i'
       <> metavar "MS"
       <> value 500
       <> showDefault
       <> help "Poll interval in milliseconds"
        )
  <*> switch (long "debug" <> help "Enable debug logging")

initCommandParser :: Parser Command
initCommandParser = pure CmdInit

-- | Options relevant to watch mode.
-- host/port come from synapse.config.json (not CLI flags for watch).
watchOptionsParser :: Parser Options
watchOptionsParser = (\cacheDir debug synapse hub token tokenFile ->
  defaultOptions
    { optInstallDeps    = False
    , optBuild          = False
    , optRunTests       = False
    , optCacheDir       = cacheDir
    , optDebug          = debug
    , optSynapsePath    = synapse
    , optHubCodegenPath = hub
    , optToken          = token
    , optTokenFile      = tokenFile
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
  <*> optional (T.pack <$> option str (long "token" <> short 't' <> metavar "JWT" <> help "JWT auth token (overrides SYNAPSE_TOKEN, --token-file, ~/.plexus/tokens/<backend>)"))
  <*> optional (option str (long "token-file" <> metavar "PATH" <> help "Read JWT token from file"))

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
  <*> optional (T.pack <$> option str
      ( long "token"
     <> short 't'
     <> metavar "JWT"
     <> help "JWT auth token (overrides SYNAPSE_TOKEN env, --token-file, ~/.plexus/tokens/<backend>)"
      ))
  <*> optional (option str
      ( long "token-file"
     <> metavar "PATH"
     <> help "Read JWT token from file (overrides ~/.plexus/tokens/<backend>)"
      ))

-- ============================================================================
-- Version Info
-- ============================================================================

-- | Version information
versionInfo :: Text
versionInfo = "synapse-cc v" <> synapseCCVersion
