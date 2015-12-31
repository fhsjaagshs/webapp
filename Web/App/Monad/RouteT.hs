{-# LANGUAGE TupleSections #-}

module Web.App.Monad.RouteT
(
  -- * RouteT monad transformer
  RouteT(..),
  -- * Monadic actions
  evalRouteT,
  writeBody,
  getState,
  setState,
  request,
  addHeader,
)
where
  
import Web.App.State
  
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Concurrent.STM

import Network.Wai
import Network.HTTP.Types.Status
import Network.HTTP.Types.Header

import Data.Maybe

import Blaze.ByteString.Builder
import Data.ByteString.Char8 (ByteString)

newtype RouteT s m a = RouteT {
  runRouteT :: (TVar s)
            -> Request
            -> m (a, Maybe Status, ResponseHeaders, StreamingBody)
}

instance (WebAppState s, Functor m) => Functor (RouteT s m) where
  fmap f m = RouteT $ \st req -> fmap (\(a,s,h,b) -> (f a,s,h,b)) $ runRouteT m st req
  
instance (WebAppState s, Monad m) => Applicative (RouteT s m) where
  pure a = RouteT $ \_ _ -> return (a,Nothing,[],nullBody)
  RouteT mf <*> RouteT mx = RouteT $ \st req -> do
    ~(f, s, h, bdy) <- mf st req
    ~(x, s', h', bdy') <- mx st req
    return (f x, seqStatus s s', h ++ h', appendBody bdy bdy')

instance (WebAppState s, Monad m) => Monad (RouteT s m) where
  fail msg = RouteT $ \_ _ -> fail msg
  m >>= k = RouteT $ \st req -> do
    ~(a, s, h, bdy) <- runRouteT m st req
    ~(b, s', h', bdy') <- runRouteT (k a) st req
    return (b, seqStatus s s', h ++ h', appendBody bdy bdy')
    
instance (WebAppState s) => MonadTrans (RouteT s) where
  lift m = RouteT $ \_ _ -> m >>= return . (,Nothing,[],nullBody)

instance (WebAppState s, MonadIO m) => MonadIO (RouteT s m) where
  liftIO = lift . liftIO
  
{- Status operations -}
  
seqStatus :: Maybe Status -> Maybe Status -> Maybe Status
seqStatus (Just a) Nothing = Just a
seqStatus Nothing (Just b) = Just b
seqStatus Nothing Nothing = Nothing
seqStatus (Just _) (Just b) = Just b
  
{- Body operations -}
  
nullBody :: StreamingBody
nullBody = \_ _ -> return ()

mkBody :: Builder -> StreamingBody
mkBody b = \w f -> (w b) >> f

appendBody :: StreamingBody -> StreamingBody -> StreamingBody
appendBody a b = \w f -> a w f >> b w f
  
{- Monadic actions -}
  
evalRouteT :: (WebAppState s, Monad m) => TVar s -> RouteT s m () -> Request -> m Response
evalRouteT st act req = do
  ~(_,s,h,bdy) <- runRouteT act st req
  return $ responseStream (fromMaybe status200 s) h bdy

writeBody :: (WebAppState s, MonadIO m) => Builder -> RouteT s m ()
writeBody builder = RouteT $ \_ _ -> return ((),Nothing,[],mkBody builder)
  
getState :: (WebAppState s, MonadIO m) => RouteT s m s
getState = RouteT $ \st _ -> do
  v <- liftIO $ readTVarIO st
  return (v,Nothing,[],nullBody)

setState :: (WebAppState s, MonadIO m) => s -> RouteT s m ()
setState newST = RouteT $ \st _ -> do
  liftIO $ atomically $ writeTVar st newST
  return ((),Nothing,[],nullBody)
  
request :: (WebAppState s, MonadIO m) => RouteT s m Request
request = RouteT $ \_ req -> return (req,Nothing,[],nullBody)

addHeader :: (WebAppState s, MonadIO m) => HeaderName -> ByteString -> RouteT s m ()
addHeader k v = RouteT $ \_ _ -> return ((),Nothing,[(k,v)],nullBody)