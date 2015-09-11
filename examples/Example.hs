import Control.Concurrent.STM.Notify
import Control.Concurrent


main = do
  let s = "Hello World!"
  let newS = "Goodnight World!"
  
  print s
  
  (env, addr) <- spawnIO s     -- Spawn an Envelope and address for strings
  
  forkOnChange env $ \_ -> do
    changingS <- recvIO env
    print changingS

  sendIO addr "Too Fast!"      -- for some reason this doesn't get picked up
                               -- maybe registering a forkOnChange requires time

  threadDelay 5000             -- Wait some time for the repl
  sendIO addr newS             -- Send another string to the address
  return ()