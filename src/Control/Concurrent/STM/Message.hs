{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Control.Concurrent.STM.Message (
  Message
, runMessages
, recvMessage
, sendMessage
) where

import           Control.Concurrent.STM

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Monad
import           Data.Monoid
import           Data.Maybe
import           Control.Concurrent.STM.Notify
import Control.Monad.Trans (MonadIO(..))


-- | A restricted monad for only doing non-blocking
-- message sending a receiving
newtype Message a = Message { unMessage :: IO a }
  deriving (Monad, Functor, Applicative)

runMessages :: Message a -> IO a
runMessages = unMessage

recvMessage :: STMEnvelope a -> Message a
recvMessage = Message . recvIO

sendMessage :: STMAddress a -> Message Bool
sendMessage = Message . sendIO

