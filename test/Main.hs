module Main (main) where

import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "SynapseCC" $ do
    it "placeholder" $ do
      True `shouldBe` True
