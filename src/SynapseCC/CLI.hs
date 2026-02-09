-- | Command-line interface parsing
module SynapseCC.CLI
  ( parseArgs
  , versionInfo
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.FilePath ((</>))

import SynapseCC.Types

-- ============================================================================
-- CLI Parser
-- ============================================================================

-- | Parse command-line arguments into Config
parseArgs :: IO Config
parseArgs = execParser opts
  where
    opts = info (configParser <**> helper)
      ( fullDesc
     <> progDesc "Unified compiler toolchain for Plexus backends"
     <> header "synapse-cc - from schema to compiled client in one command"
      )

-- | Main config parser
configParser :: Parser Config
configParser = Config
  <$> targetParser
  <*> backendParser
  <*> urlParser
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

-- | Parse WebSocket URL
urlParser :: Parser Text
urlParser = T.pack <$> argument str
  ( metavar "URL"
 <> help "Backend WebSocket URL (e.g., ws://localhost:4444)"
  )

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
  <*> option auto
      ( long "bundle-transport"
     <> metavar "BOOL"
     <> value (optBundleTransport defaultOptions)
     <> showDefault
     <> help "Bundle transport code (true/false)"
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
      ( long "watch"
     <> help "Watch backend and regenerate on changes"
      )
  <*> switch
      ( long "debug"
     <> help "Enable debug logging"
      )

-- ============================================================================
-- Version Info
-- ============================================================================

-- | Version information
versionInfo :: Text
versionInfo = "synapse-cc v0.1.0"
