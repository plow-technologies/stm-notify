module Control.Concurrent.STM.Notify (
    spawnIO
  , spawn
  , recvIO
  , recv
  , sendIO
  , send
  , forkOnChange
  , onChange
  , foldOnChange
)where

import           Control.Concurrent.STM

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Monad
import           Data.Monoid


data STMEnvelope a = STMEnvelope {
  _stmEnvelopeTMvar :: STM (Maybe ()) -- ^ Action to read and wait for the current status
, stmEnvelopeVal   :: STM a           -- ^ Actualy value of the 
}

newtype Address a = Address { _unAddress :: a -> STM Bool }

instance Functor STMEnvelope where
  fmap f (STMEnvelope n v) = STMEnvelope n (f <$> v)

instance Applicative STMEnvelope where
  pure r = STMEnvelope (return $ Just ()) (return r)
  (STMEnvelope n f) <*> (STMEnvelope n2 x) = STMEnvelope ((<>) <$> n  <*> n2) (f <*> x)  

instance Monad STMEnvelope where
  return r = STMEnvelope (return $ Just ()) (return r)
  (STMEnvelope _ v) >>= f = STMEnvelope (return $ Just ()) $ join $ (stmEnvelopeVal <$> f) <$> v

instance (Monoid a) => Monoid (STMEnvelope a) where
  mappend (STMEnvelope n1 v1) (STMEnvelope n2 v2) = STMEnvelope ((<>) <$> n1 <*> n2) ((<>) <$> v1 <*> v2)
  mempty = STMEnvelope (return $ Just ()) (return mempty)

-- | Spawn a new mailbox and an address to send new data to
spawnIO :: a -> IO (STMEnvelope a, Address a)
spawnIO = atomically . spawn


-- | Spawn a new mailbox and an address to send new data to
spawn :: a -> STM (STMEnvelope a, Address a)
spawn v = do
  t <- newTVar v
  n <- newTMVar ()
  return (STMEnvelope (tryTakeTMVar n) (readTVar t), Address (\a -> writeTVar t a >> tryPutTMVar n ()))

-- | Read the current contents of a mailbox
recvIO :: STMEnvelope a -> IO a
recvIO = atomically . stmEnvelopeVal

-- | Read the current contents of a mailbox
recv :: STMEnvelope a -> STM a
recv = stmEnvelopeVal

-- | Update the contents of a mailbox for a specific address
-- and notify the watching thread
sendIO :: Address a -> a -> IO Bool
sendIO m v = atomically $ send m v

-- | Update the contents of a mailbox for a specific address
-- and notify the watching thread
send :: Address a -> a -> STM Bool
send (Address sendF) = sendF

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
onChange (STMEnvelope n v) f = forever $ do
  v' <- atomically $ do
    n' <- n
    case n' of
      Nothing -> retry
      Just _ -> v
  f v'
  return ()

-- | fold across a value each time the envelope is updated
foldOnChange :: STMEnvelope a     -- ^ Envelop to watch
             -> (b -> a -> IO b)  -- ^ fold like function
             -> b                 -- ^ Initial value
             -> IO ()
foldOnChange e@(STMEnvelope n v) fld i = do
  v' <- atomically $ do
    n' <- n
    case n' of
      Nothing -> retry
      Just _ -> v
  i' <- fld i v'
  foldOnChange e fld i'