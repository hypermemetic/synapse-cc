-- | Command-line interface parsing
module SynapseCC.CLI
  ( parseArgs
  , synapseCCParserInfo
  , versionInfo
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative

import SynapseCC.Types

-- ============================================================================
-- CLI Parser
-- ============================================================================

-- | Full parser info (usable with execParserPure for in-process testing)
synapseCCParserInfo :: ParserInfo Config
synapseCCParserInfo = info (configParser <**> helper <**> simpleVersioner (T.unpack versionInfo))
  ( fullDesc
 <> progDesc "Unified compiler toolchain for Plexus backends"
 <> header "synapse-cc - from schema to compiled client in one command"
  )

-- | Parse command-line arguments into Config
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
