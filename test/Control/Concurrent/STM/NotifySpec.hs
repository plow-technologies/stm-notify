module Control.Concurrent.STM.NotifySpec (main, spec) where

import           Test.Hspec

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Concurrent.STM.Notify

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  specModifyingValue





specModifyingValue :: Spec
specModifyingValue = do
  describe "Modifying an envelope" $ do
    it "should modify and update a list" $ do
      (env, addr) <- spawnIO 0
      (listEnv, listAddr) <- spawnIO []
      forkOnChange env (\i -> do
        atomically $ do
          xs <- recv listEnv
          send listAddr (xs ++ [i]))
      threadDelay 100
      mapM (sendIO addr) [1..100000]
      threadDelay 1000
      xs <- recvIO listEnv
      length xs `shouldSatisfy` (> 10000)

