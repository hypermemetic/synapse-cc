{-# LANGUAGE OverloadedStrings #-}

-- | Registry-based backend address resolution (SAFE-3).
--
-- synapse-cc previously assumed every backend lived at the registry's
-- own host:port (typically @127.0.0.1:4444@), which broke for backends
-- like @lforge@ that live on different ports. This module queries the
-- Plexus registry to map a backend name to its actual host:port.
--
-- The registry's location defaults to @127.0.0.1:4444@; pass
-- @--host@\/@--port@ to override.
--
-- Resolution flow:
--
--  1. Query @registry.get@ at the given registry address for the named backend.
--  2. If found, return the registered host:port.
--  3. If the backend is not registered, list known backends and fail.
--  4. If the registry itself is unreachable, fall back to the registry
--     address as the backend address (preserves the legacy "substrate IS
--     the registry on 4444" path) and warn.
module SynapseCC.RegistryResolve
  ( ResolveResult(..)
  , resolveBackendAddress
  ) where

import Control.Exception (try, SomeException)
import Data.Text (Text)

import qualified Synapse.Backend.Discovery as D

-- | Outcome of resolving a backend name against the registry.
data ResolveResult
  = ResolvedFromRegistry  !Text !Int  -- ^ Backend found in registry: returned host, port
  | ResolvedFallback      !Text !Int  -- ^ Registry unreachable: falling back to provided address
  | NotInRegistry         ![Text]     -- ^ Backend not in registry; suggestions = known backend names
  deriving stock (Show, Eq)

-- | Resolve a backend name to a host:port using the registry at the
-- provided address. Always returns SOMETHING — never throws.
resolveBackendAddress
  :: Text   -- ^ registry host (also fallback)
  -> Int    -- ^ registry port (also fallback)
  -> Text   -- ^ backend name to resolve
  -> IO ResolveResult
resolveBackendAddress regHost regPort bkName = do
  let discovery = D.registryDiscovery regHost regPort
  -- Try to look up the named backend.
  result <- try (D.getBackendInfo discovery bkName) :: IO (Either SomeException (Maybe D.Backend))
  case result of
    Right (Just b) ->
      pure $ ResolvedFromRegistry (D.backendHost b) (D.backendPort b)
    Right Nothing -> do
      -- Backend not in registry. Try to list registered ones for a helpful error.
      knownE <- try (D.discoverBackends discovery) :: IO (Either SomeException [D.Backend])
      let known = case knownE of
            Right bs -> map D.backendName bs
            Left _   -> []
      pure $ NotInRegistry known
    Left _ ->
      -- Registry call failed (registry unreachable or RPC error).
      -- Fall back to the registry address as the backend address —
      -- preserves the "substrate is reachable on the same port" legacy path.
      pure $ ResolvedFallback regHost regPort
