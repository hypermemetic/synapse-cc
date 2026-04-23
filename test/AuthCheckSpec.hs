{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- | SAFE-6 acceptance tests for SynapseCC.AuthCheck.
module Main where

import Data.Aeson (Value, eitherDecodeStrict)
import Data.Aeson.QQ.Simple (aesonQQ)
import qualified Data.IORef as IORef
import qualified Data.Text as T
import Data.Text (Text)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))
import qualified System.IO.Temp as Temp
import qualified Data.Text.IO as TIO
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Aeson as Aeson

import SynapseCC.AuthCheck (backendRequiresCookieAuth, detectCookieAuthMismatch)

-- ─── Fixtures ─────────────────────────────────────────────────

irWithAuthMethod :: Value
irWithAuthMethod = [aesonQQ|{
  "irVersion": "2.0",
  "irBackend": "test",
  "irMethods": {
    "svc.list": {
      "mdName": "list",
      "mdFullPath": "svc.list",
      "mdNamespace": "svc",
      "mdParams": [
        { "pdName": "user",
          "pdType": {"tag":"RefPrimitive","contents":["string",null]},
          "pdRequired": false,
          "pdSource": { "from": "auth", "resolver": "self.db.validate_user" }
        },
        { "pdName": "search",
          "pdType": {"tag":"RefPrimitive","contents":["string",null]},
          "pdRequired": false
        }
      ]
    }
  }
}|]

irWithoutAuthMethods :: Value
irWithoutAuthMethods = [aesonQQ|{
  "irVersion": "2.0",
  "irBackend": "test",
  "irMethods": {
    "svc.ping": {
      "mdName": "ping",
      "mdFullPath": "svc.ping",
      "mdNamespace": "svc",
      "mdParams": [
        { "pdName": "message",
          "pdType": {"tag":"RefPrimitive","contents":["string",null]},
          "pdRequired": true
        }
      ]
    }
  }
}|]

irWithCookieButNoAuth :: Value
irWithCookieButNoAuth = [aesonQQ|{
  "irVersion": "2.0",
  "irBackend": "test",
  "irMethods": {
    "svc.origin_log": {
      "mdName": "origin_log",
      "mdFullPath": "svc.origin_log",
      "mdNamespace": "svc",
      "mdParams": [
        { "pdName": "origin",
          "pdType": {"tag":"RefPrimitive","contents":["string",null]},
          "pdRequired": false,
          "pdSource": { "from": "header", "key": "origin" }
        }
      ]
    }
  }
}|]

-- ─── Runner ───────────────────────────────────────────────────

data TestResult = Pass String | Fail String String

main :: IO ()
main = do
  failures <- IORef.newIORef (0 :: Int)
  let run (Pass name)        = putStrLn $ "  [PASS] " <> name
      run (Fail name reason) = do
        putStrLn $ "  [FAIL] " <> name <> ": " <> reason
        IORef.modifyIORef' failures (+ 1)

  putStrLn "=== SAFE-6: backendRequiresCookieAuth detection ==="

  run $ boolCase "IR with #[from_auth] method → detected as requiring cookie auth"
    (backendRequiresCookieAuth irWithAuthMethod) True

  run $ boolCase "IR with only RPC params → not detected"
    (backendRequiresCookieAuth irWithoutAuthMethods) False

  run $ boolCase "IR with cookie/header params but no auth → not detected"
    (backendRequiresCookieAuth irWithCookieButNoAuth) False

  putStrLn "=== SAFE-6: detectCookieAuthMismatch end-to-end ==="

  Temp.withSystemTempDirectory "safe6" $ \tmp -> do
    let irFile   = tmp </> "ir.json"
        tsFile   = tmp </> "transport.ts"
    BS.writeFile irFile (BL.toStrict (Aeson.encode irWithAuthMethod))

    -- Case 1: auth required, no prior transport.ts → no warning
    r1 <- detectCookieAuthMismatch irFile tmp
    run $ case r1 of
      Nothing -> Pass "first build (no transport.ts) → no warning"
      Just _  -> Fail "first build" "expected Nothing; got warning"

    -- Case 2: auth required, transport.ts lacks SAFE-7 marker → warning
    TIO.writeFile tsFile "// legacy transport.ts, no marker\nexport const ws = null;"
    r2 <- detectCookieAuthMismatch irFile tmp
    run $ case r2 of
      Just w | "SAFE-6" `T.isInfixOf` w && "cookie" `T.isInfixOf` w ->
        Pass "stale transport.ts + auth required → warning mentions SAFE-6 + cookie"
      Just _  -> Fail "stale transport.ts" "got a warning but wrong content"
      Nothing -> Fail "stale transport.ts" "expected warning; got Nothing"

    -- Case 3: auth required, transport.ts contains SAFE-7 marker → no warning
    TIO.writeFile tsFile "// SAFE-7-cookie-auth-marker: ok\nexport const ws = null;"
    r3 <- detectCookieAuthMismatch irFile tmp
    run $ case r3 of
      Nothing -> Pass "SAFE-7-marked transport.ts → no warning"
      Just _  -> Fail "marked transport.ts" "expected Nothing; got warning"

    -- Case 4: no auth in backend → no warning regardless of transport.ts
    BS.writeFile irFile (BL.toStrict (Aeson.encode irWithoutAuthMethods))
    r4 <- detectCookieAuthMismatch irFile tmp  -- transport.ts still marked from case 3
    run $ case r4 of
      Nothing -> Pass "no-auth backend → no warning regardless of transport.ts"
      Just _  -> Fail "no-auth backend" "expected Nothing; got warning"

  fc <- IORef.readIORef failures
  if fc == 0
    then putStrLn "\nSAFE-6: ALL TESTS PASSED" >> exitSuccess
    else putStrLn ("\nSAFE-6: " <> show fc <> " test(s) failed") >> exitFailure

boolCase :: String -> Bool -> Bool -> TestResult
boolCase name got want
  | got == want = Pass name
  | otherwise   = Fail name ("expected " <> show want <> ", got " <> show got)
