{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TupleSections     #-}
module Control.Concurrent.STM.Notify (
    Envelope
  , Address
  , Mailbox
  , spawnIO
  , recvIO
  , sendIO
  , forkOnChange
  , onChange
  , foldOnChange
  , notify
  , waitForChanges
  , watchOn
  , addListener
  , foldOnChangeWith
)where

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Concurrent.MVar
import           Control.Monad            hiding (mapM, sequence)
import           Data.Traversable         (traverse)
import           Prelude                  hiding (mapM, sequence)


type Mailbox a = (Envelope a, Address a)

data Envelope a = Envelope {
  envelopeTMvar :: IO ([MVar ()],a) -- ^ Current list of waiting listeners and the current value
, addListener   :: MVar () -> IO () -- ^ Add a listener to the envelope
}


-- A wrapper to send an item to its paried container
newtype Address a = Address { _unAddress :: a -> IO () }


instance Functor Envelope where
  fmap f (Envelope readCurrentValue insertListener) = Envelope newStmVal newInsertListener
    where newInsertListener = insertListener -- Keep the same listener
          newStmVal = fmap f <$> readCurrentValue -- Apply f to the current value
                                          -- (<$> over STM and fmap over the tuple)

instance Applicative Envelope where
  pure r = Envelope (return ([], r)) (const $ return ())
  -- Empty list of listeners and a function that doesn't add anything
  -- Because there is no way to modify this value by default
  (Envelope env1 insertListener1) <*> (Envelope env2 insertListener2) = Envelope newStmVal newAddListener
    where newStmVal = (\(fList,f) (valList, val) -> (fList ++ valList, f val)) <$> env1 <*> env2 -- Apply the function to the value
          newAddListener t = insertListener1 t >> insertListener2 t -- Use both listeners to allow for listening to multiple changes


-- instance Alternative Envelope where
--   empty = Envelope empty (const $ return ())
--   (Envelope val listener) <|> (Envelope val' listener') = Envelope (val <|> val') (\t -> listener t >> listener' t)

instance Monad Envelope where
  return r = Envelope (return ([], r)) (const $ return ())
  (Envelope stmVal insertListener) >>= f = Envelope stmNewVal newInsertListener
    where stmNewVal = fst <$> updateFcnVal
          newInsertListener = fixAddFunc $ snd <$> updateFcnVal
          updateFcnVal = do
            (listeners, currentVal) <- stmVal
            let (Envelope stmRes insertListener') = f currentVal
                add t = insertListener' t >> insertListener t
            (listeners', newVal) <- stmRes
            return ((listeners' ++ listeners, newVal), add)
          fixAddFunc func tm =  ($ tm) =<< func

-- | Spawn a new envelope and an address to send new data to
spawnIO :: a -> IO (Envelope a, Address a)
spawnIO = undefined

-- | Spawn a new envelope and address inside of an envelope computation
-- spawnEnvelope :: a -> Envelope (Envelope a, Address a)
-- spawnEnvelope x = Envelope (([],) <$> spawned) addListener
--   where spawned = spawn x
--         addListener = fixStm (addListener . fst <$> spawned)
--         fixStm f x = ($ x) =<< f

-- | Spawn a new envelope and an address to send new data to
-- spawn :: a -> STM (Envelope a, Address a)
-- spawn val = do
--   tValue <- newTMVar ([],val)                                -- Contents with no listeners
--   let envelope = Envelope (readTMVar tValue) insertListener  -- read the current value and an add function
--       insertListener listener = do
--         (listeners, a) <- takeTMVar tValue                   -- Get the list of listeners to add
--         putTMVar tValue (listener:listeners, a)              -- append the new listener
--       address = Address $ \newVal -> do
--         (listeners,_) <- takeTMVar tValue                    -- Find the listeners
--         putTMVar tValue ([],newVal)                        -- put the new value with no listeners
--         mapM_ (`tryPutTMVar`  ()) listeners                 -- notify all the listeners of the change
--   return (envelope, address)


-- | Force a notification event. This doesn't clear the listeners
notify :: Envelope a -> IO ()
notify (Envelope readCurrentValue _) = do
  (listeners, _) <- readCurrentValue                                   -- Get a list of all current listeners
  mapM_ (`tryPutMVar` ()) listeners                       -- Fill all of the tmvars


-- | Read the current contents of a envelope
recvIO :: Envelope a -> IO a
recvIO = undefined

-- | Read the current contents of a envelope
-- recv :: Envelope a -> STM a
-- recv = fmap snd . EnvelopeTMvar

-- | Update the contents of a envelope for a specific address
-- and notify the watching thread
sendIO :: Address a -> a -> IO ()
sendIO (Address sendF) v = sendF v

-- | Update the contents of a envelope for a specific address
-- and notify the watching thread
-- send :: Address a -> a -> STM ()
-- send (Address sendF) = sendF

-- | Watch the envelope in a thread. This is the only thread that
-- can watch the envelope. This never ends
forkOnChange :: Envelope a -- ^ Envelope to watch
             -> (a -> IO b)  -- ^ Action to perform
             -> IO (Async b) -- ^ Resulting async value so that you can cancel
forkOnChange v f = async $ onChange v f

-- | Watch the envelope for changes. This never ends
onChange :: Envelope a -- ^ Envelope to watch
         -> (a -> IO b)  -- ^ Action to perform
         -> IO b
onChange env f = forever $ waitForChange env >> (f =<< recvIO env)

onChangeWith :: (a -> [Envelope a])
             -> Envelope a
             -> (a -> IO b)
             -> IO ()
onChangeWith children env f = void . forever $ do
  watch <- newEmptyMVar
  go children watch env
  readMVar watch
  _ <- f =<< recvIO env
  return ()
    where go getChildren watch env = do
            current <- recvIO env
            addListener env watch
            mapM_ (go getChildren watch) $ getChildren current

forkOnChangeWith :: (a -> [Envelope a])
                 -> Envelope a
                 -> (a -> IO b)
                 -> IO (Async ())
forkOnChangeWith getC env f = async $ onChangeWith getC env f

waitForChange :: Envelope a -> IO ()
waitForChange (Envelope _ insertListener) = do
  x <- newEmptyMVar
  insertListener x            -- This is two seperate transactions because readTMVar will fail
  readMVar x              -- Causing insertListener to retry


waitForChanges :: (a -> [a]) -> (a -> Envelope b) -> a -> IO ()
waitForChanges getChildren getEnv start = do
  listener <- newEmptyMVar
  go listener getChildren getEnv start
  where go listener getCh env val = do
              let insertListener = addListener $ getEnv start
              insertListener listener
              mapM_ (go listener getCh env) $ getCh val



-- -- | fold across a value each time the envelope is updated
foldOnChange :: Envelope a     -- ^ Envelop to watch
             -> (b -> a -> IO b)  -- ^ fold like function
             -> b                 -- ^ Initial value
             -> IO ()
foldOnChange = foldOnChangeWith waitForChange



foldOnChangeWith :: (Envelope a -> IO ()) -- ^ Function to wait for a change
             -> Envelope a     -- ^ Envelop to watch
             -> (b -> a -> IO b)  -- ^ fold like function
             -> b                 -- ^ Initial value
             -> IO ()
foldOnChangeWith waitFunc env fld accum = do
  _ <- waitFunc env
  val <- recvIO env -- wait for the lock and then read the value
  accum' <- fld accum val
  foldOnChangeWith waitFunc env fld accum'


watchOn :: (a -> Envelope [a]) -> Envelope a -> IO ()
watchOn f stmVal = do
  listener <- newEmptyMVar
  addListener stmVal listener
  currentVal <- recvIO stmVal
  let envCh = f currentVal
  children <- recvIO envCh
  mapM_ (go listener f) children
  readMVar listener
  where go listener func val = do
          let envChildren = func val
          addListener envChildren listener
          ch <- recvIO envChildren
          mapM_ (go listener func) ch

-- addListener :: Envelope a -> TMVar () -> STM ()
-- addListener = addListener
