{-# LANGUAGE NoImplicitPrelude #-}
module Control.Concurrent.STM.Notify (
    STMEnvelope(..)
  , Address
  , spawnIO
  , spawn
  , recvIO
  , recv
  , sendIO
  , send
  , forkOnChange
  , onChange
  , foldOnChange
  , STMMailbox
)where

import           Control.Concurrent.STM
import           Prelude                  hiding (sequence)

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Monad            hiding (sequence)
import           Data.Maybe
import           Data.Monoid
import           Data.Traversable


type STMMailbox a = (STMEnvelope a, Address a)

data STMEnvelope a = STMEnvelope {
  _stmEnvelopeTMvar :: [STM (TMVar ())]    -- ^ Action to read and wait for the current status
, stmEnvelopeVal    :: STM a           -- ^ Actualy value of the
}



newtype Address a = Address { _unAddress :: a -> STM (Bool, TMVar ()) }


readOne :: [STM a] -> STM a
readOne xs = do
  let xs' = map alwaysRead xs
  processed <- catMaybes <$> sequence xs'
  if length processed > 0
    then return $ head processed
    else retry

alwaysRead :: STM a -> STM (Maybe a)
alwaysRead x =  (Just <$> x) <|> return Nothing

instance Functor STMEnvelope where
  fmap f (STMEnvelope n v) = STMEnvelope n (f <$> v)

instance Applicative STMEnvelope where
  pure r = STMEnvelope empty (return r)
  (STMEnvelope n f) <*> (STMEnvelope n2 x) = STMEnvelope (n <|> n2) (f <*> x)

instance Monad STMEnvelope where
  return r = STMEnvelope empty (return r)
  (STMEnvelope n v) >>= f = STMEnvelope n $ join $ (stmEnvelopeVal <$> f) <$> v

instance (Monoid a) => Monoid (STMEnvelope a) where
  mappend (STMEnvelope n1 v1) (STMEnvelope n2 v2) = STMEnvelope (n1 <|> n2) ((<>) <$> v1 <*> v2)
  mempty = STMEnvelope empty (return mempty)

-- | Spawn a new envelope and an address to send new data to
spawnIO :: a -> IO (STMEnvelope a, Address a)
spawnIO = atomically . spawn


-- | Spawn a new envelope and an address to send new data to
-- spawn :: a -> STM (STMEnvelope a, Address a)
-- spawn val = do
--   tValue <- newTVar val
--   innerSignal <- newEmptyTMVar :: STM (TMVar ())
--   tmSignal <- newTVar innerSignal :: STM (TVar (TMVar ()))
--   return (STMEnvelope (readTVar tmSignal) (readTVar tValue), Address (\a -> signal (readTVar tmSignal) >> tryPutTMVar signal ()))

spawn :: a -> STM (STMEnvelope a, Address a)
spawn val = do
  tValue <- newTVar val
  innerSignal <- newEmptyTMVar :: STM (TMVar ())
  tmSignal <- newTVar innerSignal :: STM (TVar (TMVar ()))
  let signalContainer = readTVar tmSignal
      envelope = STMEnvelope [signalContainer] (readTVar tValue)
      address = Address $ \a -> do
        oldSignal <- signalContainer    -- Old place to notify of changes
        newInnerSignal <- newEmptyTMVar -- new method of signalling
        writeTVar tValue a
        writeTVar tmSignal newInnerSignal     -- Put the new signal in the container (done before notifying so that the new process can get the current signal)
        res <- tryPutTMVar oldSignal ()        -- Notify of change
        return (res, newInnerSignal)
  return $ (envelope, address)

-- | Read the current contents of a envelope
recvIO :: STMEnvelope a -> IO a
recvIO = atomically . stmEnvelopeVal

-- | Read the current contents of a envelope
recv :: STMEnvelope a -> STM a
recv = stmEnvelopeVal

-- | Update the contents of a envelope for a specific address
-- and notify the watching thread
sendIO :: Address a -> a -> IO Bool
sendIO m v = atomically $ send m v

-- | Update the contents of a envelope for a specific address
-- and notify the watching thread
send :: Address a -> a -> STM Bool
send (Address sendF) new = fst <$> sendF new

-- | Watch the envelope in a thread. This is the only thread that
-- can watch the envelope. This never ends
forkOnChange :: STMEnvelope a -- ^ Envelope to watch
             -> (a -> IO b)  -- ^ Action to perform
             -> IO (Async ()) -- ^ Resulting async value so that you can cancel
forkOnChange v f = async $ onChange v f

-- | Watch the envelope for changes. This never ends
onChange :: STMEnvelope a -- ^ Envelope to watch
         -> (a -> IO b)  -- ^ Action to perform
         -> IO ()
onChange env@(STMEnvelope _ valueContainer) f = forever $ do
  _ <- waitForChange env
  value <- atomically $ valueContainer
  _ <- f value
  return ()


waitForChange :: STMEnvelope a -> IO ()
waitForChange (STMEnvelope notifyContainer _) = do
  notifyTMVars <- atomically $ sequence notifyContainer  :: IO [TMVar ()]
  atomically $ readOne (readTMVar <$> notifyTMVars)


getHasChanged :: STMEnvelope a -> STM (STM Bool)
getHasChanged (STMEnvelope notifyContainer _) = do
  notifyTMVars <- sequence notifyContainer :: STM [TMVar ()]
  return $ or <$> traverse isEmptyTMVar notifyTMVars

-- | fold across a value each time the envelope is updated
-- foldOnChange :: STMEnvelope a     -- ^ Envelop to watch
--              -> (b -> a -> IO b)  -- ^ fold like function
--              -> b                 -- ^ Initial value
--              -> IO ()
-- foldOnChange e@(STMEnvelope _ v) fld i = go
--   where go = do
--               _ <- waitForChange e
--               stmHasChanged <- atomically $ getHasChanged e
--               v' <- atomically v -- wait for the lock and then read the value
--               i' <- fld i v'
--               hasChanged <- atomically stmHasChanged
--               newI <- if hasChanged
--                 then Just <$> go' i'
--                 else return Nothing
--               foldOnChange e fld $ fromMaybe i' newI
--         go' new = do
--                     stmHasChanged <- atomically $  getHasChanged e
--                     v' <- atomically v -- wait for the lock and then read the value
--                     i' <- fld new v'
--                     hasChanged <- atomically stmHasChanged
--                     newI <- if hasChanged
--                       then Just <$> go' i'
--                       else return Nothing
--                     return $ fromMaybe i' newI

-- | fold across a value each time the envelope is updated
foldOnChange :: STMEnvelope a     -- ^ Envelop to watch
             -> (b -> a -> IO b)  -- ^ fold like function
             -> b                 -- ^ Initial value
             -> IO ()
foldOnChange e@(STMEnvelope _ v) fld i = do
  _ <- waitForChange e
  v' <- atomically v -- wait for the lock and then read the value
  i' <- fld i v'
  foldOnChange e fld i'
