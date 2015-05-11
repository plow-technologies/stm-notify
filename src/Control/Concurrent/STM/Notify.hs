{-# LANGUAGE NoImplicitPrelude #-}
module Control.Concurrent.STM.Notify (
    STMEnvelope
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
  , notify
)where

import           Control.Concurrent.STM
import           Prelude                  hiding (sequence, mapM)

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Monad            hiding (sequence, mapM)


type STMMailbox a = (STMEnvelope a, Address a)

data STMEnvelope a = STMEnvelope {
  stmEnvelopeTMvar :: STM ([TMVar ()],a)   -- ^ Current list of waiting listeners and the current value
, stmAddListener :: TMVar () -> STM ()     -- ^ Add a listener to the envelope
}



newtype Address a = Address { _unAddress :: a -> STM () }


instance Functor STMEnvelope where
  fmap f (STMEnvelope stmVal addListener) = STMEnvelope newStmVal newAddListener
    where newAddListener = addListener -- Keep the same listener
          newStmVal = (fmap f) <$> stmVal -- Apply f to the current value (second argument of the tuple)

instance Applicative STMEnvelope where
  pure r = STMEnvelope (return ([], r)) (const $ return ()) -- Empty list of listeners and a function that doesn't add anything
                                                            -- Because there is no way to modify this value by default
  (STMEnvelope env1 addListener1) <*> (STMEnvelope env2 addListener2) = STMEnvelope newStmVal newAddListener
    where newStmVal = (\(fList,f) (valList, val) -> (fList ++ valList, f val)) <$> env1 <*> env2 -- Apply the function to the value
          newAddListener t = addListener1 t >> addListener2 t -- Use both listeners to allow for listening to multiple changes


        

instance Monad STMEnvelope where
  return r = STMEnvelope (return $ ([], r)) (const $ return ())
  (STMEnvelope stmVal addListener) >>= f = STMEnvelope stmNewVal newAddListener
    where stmNewVal = fst <$> updateFcnVal
          newAddListener = fixAddFunc $ snd <$> updateFcnVal
          updateFcnVal = do
            (listeners, currentVal) <- stmVal
            let (STMEnvelope stmRes addListener') = f currentVal
                add t = addListener' t >> addListener t
            (listeners', newVal) <- stmRes
            return (((listeners' ++ listeners), newVal), add)
          fixAddFunc func tm =  ($ tm) =<< func

-- | Spawn a new envelope and an address to send new data to
spawnIO :: a -> IO (STMEnvelope a, Address a)
spawnIO = atomically . spawn


-- | Spawn a new envelope and an address to send new data to
spawn :: a -> STM (STMEnvelope a, Address a)
spawn val = do
  tValue <- newTMVar ([],val)                                -- Contents with no listeners
  let envelope = STMEnvelope (readTMVar tValue) addListener  -- read the current value and an add function
      addListener listener = do
        (listeners, a) <- takeTMVar tValue                   -- Get the list of listeners to add
        putTMVar tValue (listener:listeners, a)              -- append the new listener
      address = Address $ \newVal -> do
        (listeners,_) <- takeTMVar tValue                    -- Find the listeners
        putTMVar tValue $ ([],newVal)                        -- put the new value with no listeners
        mapM_ (flip putTMVar $ ()) listeners                 -- notify all the listeners of the change
  return (envelope, address)


-- | Force a notification event. This doesn't clear the listeners
notify :: STMEnvelope a -> STM ()
notify (STMEnvelope stmVal _) = do
  (listeners, _) <- stmVal                                   -- Get a list of all current listeners
  mapM_ (flip putTMVar $ ()) listeners                       -- Fill all of the tmvars


-- | Read the current contents of a envelope
recvIO :: STMEnvelope a -> IO a
recvIO = atomically . recv

-- | Read the current contents of a envelope
recv :: STMEnvelope a -> STM a
recv = (fmap snd) . stmEnvelopeTMvar

-- | Update the contents of a envelope for a specific address
-- and notify the watching thread
sendIO :: Address a -> a -> IO ()
sendIO m v = atomically $ send m v

-- | Update the contents of a envelope for a specific address
-- and notify the watching thread
send :: Address a -> a -> STM ()
send (Address sendF) = sendF

-- | Watch the envelope in a thread. This is the only thread that
-- can watch the envelope. This never ends
forkOnChange :: STMEnvelope a -- ^ Envelope to watch
             -> (a -> IO b)  -- ^ Action to perform
             -> IO (Async b) -- ^ Resulting async value so that you can cancel
forkOnChange v f = async $ onChange v f

-- | Watch the envelope for changes. This never ends
onChange :: STMEnvelope a -- ^ Envelope to watch
         -> (a -> IO b)  -- ^ Action to perform
         -> IO b
onChange env f = forever $ waitForChange env >> (f =<< recvIO env)


waitForChange :: STMEnvelope a -> IO ()
waitForChange (STMEnvelope _ addListener) = do
  x <- newEmptyTMVarIO
  atomically $ addListener x            -- This is two seperate transactions because readTMVar will fail
  atomically $ readTMVar x              -- Causing addListener to retry


-- -- | fold across a value each time the envelope is updated
foldOnChange :: STMEnvelope a     -- ^ Envelop to watch
             -> (b -> a -> IO b)  -- ^ fold like function
             -> b                 -- ^ Initial value
             -> IO ()
foldOnChange env fld accum = do
  _ <- waitForChange env
  val <- recvIO env -- wait for the lock and then read the value
  accum' <- fld accum val
  foldOnChange env fld accum'
