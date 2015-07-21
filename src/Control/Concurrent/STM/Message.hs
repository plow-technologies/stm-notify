{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Control.Concurrent.STM.Message (
  Message
, runMessages
, recvMessage
, sendMessage
, modifyMailbox
, debug
, unsafeForkIO
) where


import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.STM.Notify
import           Control.Monad


-- | A restricted monad for only doing non-blocking
-- message sending a receiving
newtype Message a = Message { unMessage :: IO a }
  deriving (Monad, Functor, Applicative)

runMessages :: Message a -> IO a
runMessages = unMessage

recvMessage :: STMEnvelope a -> Message a
recvMessage = Message . recvIO

sendMessage :: Address a -> a -> Message ()
sendMessage addr m = Message $ sendIO addr m

modifyMailbox :: STMMailbox a -> (a -> a)-> Message ()
modifyMailbox (env, addr) f = do
  tg <- recvMessage env
  sendMessage addr $ f tg

debug :: String -> Message ()
debug = Message . putStrLn

unsafeForkIO :: IO () -> Message ()
unsafeForkIO = Message . void . forkIO