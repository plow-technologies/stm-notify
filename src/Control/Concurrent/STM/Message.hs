{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Control.Concurrent.STM.Message (
  Message
, runMessages
, recvMessage
, sendMessage
, modifyMailbox
) where

import           Control.Concurrent.STM

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Monad
import           Data.Monoid
import           Data.Maybe
import           Control.Concurrent.STM.Notify


-- | A restricted monad for only doing non-blocking
-- message sending a receiving
newtype Message a = Message { unMessage :: IO a }
  deriving (Monad, Functor, Applicative)

runMessages :: Message a -> IO a
runMessages = unMessage

recvMessage :: STMEnvelope a -> Message a
recvMessage = Message . recvIO

sendMessage :: Address a -> a -> Message Bool
sendMessage addr m = Message $ sendIO addr m

modifyMailbox :: STMMailbox a -> (a -> b -> a) -> b -> Message Bool
modifyMailbox (env, addr) f val = do
  tg <- recvMessage env
  sendMessage addr $ f tg val