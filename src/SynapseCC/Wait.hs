{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Wait command: block until configured backends are reachable.
--
-- Usage:
--   synapse-cc wait                         -- wait for all backends in config
--   synapse-cc wait monochrome              -- wait for one backend (URL from config)
--   synapse-cc wait monochrome -u ws://...: -- wait for explicit backend+URL
module SynapseCC.Wait
  ( runWait
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (try, SomeException)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Control.Monad (when)

import qualified Data.Aeson as Aeson
import Plexus.Client (SubstrateConfig(..), defaultConfig)
import qualified Plexus.Transport as Transport

import SynapseCC.Config (loadSynapseConfig, parseWsUrl)
import SynapseCC.Logging
import SynapseCC.Types

-- | Extract all unique (backend, url) pairs from the config.
collectEndpoints :: SynapseConfig -> [(Text, Text)]
collectEndpoints sc =
  let defaultUrl = fromMaybe "ws://127.0.0.1:4444" (scUrl sc)
      defaultBk  = fromMaybe "substrate" (scBackend sc)
      pairs = [ let bk  = fromMaybe defaultBk (tcBackend tc)
                    url = fromMaybe defaultUrl (tcUrl tc)
                in (bk, url)
              | tc <- Map.elems (scTargets sc)
              ]
  in Map.toList (Map.fromList pairs)

-- | Try to connect to a backend by calling {backend}.hash
probeBackend :: Text -> Text -> IO (Either Text ())
probeBackend backend url = do
  let (host, portTxt) = parseWsUrl url
      port = read (T.unpack portTxt) :: Int
      cfg = (defaultConfig backend)
              { substrateHost = T.unpack host
              , substratePort = port
              }
      method = backend <> ".hash"
  outcome <- try $ Transport.rpcCallWith cfg method Aeson.Null
  case outcome of
    Left (ex :: SomeException) -> pure $ Left $ T.pack (show ex)
    Right (Left err)           -> pure $ Left $ T.pack (show err)
    Right (Right _)            -> pure $ Right ()

-- | Determine which endpoints to wait for based on args.
resolveEndpoints :: WaitArgs -> IO (Either Text [(Text, Text)])
resolveEndpoints args = case waitBackend args of
  -- Explicit backend + URL: no config needed
  Just bk | Just url <- waitUrl args ->
    pure $ Right [(bk, url)]

  -- Explicit backend, URL from config
  Just bk -> do
    cfgResult <- loadSynapseConfig
    case cfgResult of
      Left err -> pure $ Left err
      Right sc -> do
        let allEps = collectEndpoints sc
        case lookup bk allEps of
          Just url -> pure $ Right [(bk, url)]
          Nothing  ->
            -- Backend not in config — try top-level URL as fallback
            let url = fromMaybe "ws://127.0.0.1:4444" (scUrl sc)
            in pure $ Right [(bk, url)]

  -- No backend specified: all from config
  Nothing -> do
    cfgResult <- loadSynapseConfig
    case cfgResult of
      Left err -> pure $ Left err
      Right sc -> do
        let eps = collectEndpoints sc
        if null eps
          then pure $ Left "no backends configured in synapse.config.json"
          else pure $ Right eps

-- | Run the wait command. Returns True on success, False on timeout/error.
runWait :: WaitArgs -> IO Bool
runWait args = do
  epResult <- resolveEndpoints args
  case epResult of
    Left err -> do
      logError err
      pure False

    Right endpoints -> do
      let n = length endpoints
          names = T.intercalate ", " [bk <> " (" <> url <> ")" | (bk, url) <- endpoints]
      logStep $ "Waiting for " <> T.pack (show n)
             <> " backend" <> (if n > 1 then "s" else "")
             <> ": " <> names
             <> " (timeout: " <> T.pack (show (waitTimeout args)) <> "s)"

      startTime <- getCurrentTime
      let timeoutSecs = fromIntegral (waitTimeout args) :: Double
          intervalUs  = waitInterval args * 1000

          loop :: Set Text -> IO Bool
          loop remaining
            | Set.null remaining = pure True
            | otherwise = do
                now <- getCurrentTime
                let elapsed = realToFrac (diffUTCTime now startTime) :: Double
                if elapsed >= timeoutSecs then do
                  logError $ "Timed out after " <> T.pack (show (waitTimeout args))
                          <> "s waiting for: "
                          <> T.intercalate ", " (Set.toList remaining)
                  pure False
                else do
                  newRemaining <- probeAll remaining endpoints
                  if Set.null newRemaining
                    then pure True
                    else do
                      threadDelay intervalUs
                      loop newRemaining

          probeAll :: Set Text -> [(Text, Text)] -> IO (Set Text)
          probeAll remaining eps = go remaining eps
            where
              go acc [] = pure acc
              go acc ((bk, url):rest)
                | not (Set.member bk acc) = go acc rest
                | otherwise = do
                    result <- probeBackend bk url
                    case result of
                      Right () -> do
                        logSuccess $ bk <> " reachable"
                        go (Set.delete bk acc) rest
                      Left _ -> do
                        when (waitDebug args) $
                          logInfo $ "  " <> bk <> " not yet reachable"
                        go acc rest

      let backendNames = Set.fromList [bk | (bk, _) <- endpoints]
      loop backendNames
