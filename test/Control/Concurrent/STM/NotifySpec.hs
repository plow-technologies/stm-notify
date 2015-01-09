module Control.Concurrent.STM.NotifySpec (main, spec) where

import Test.Hspec

import Control.Concurrent.STM.Notify

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "someFunction" $ do
    it "should work fine" $ do
      True `shouldBe` False
