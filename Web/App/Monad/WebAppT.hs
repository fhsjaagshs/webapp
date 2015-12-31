{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving #-}

{-|
Module      : Web.App.Monad.WebAppT
Copyright   : (c) Nathaniel Symer, 2015
License     : MIT
Maintainer  : nate@symer.io
Stability   : experimental
Portability : POSIX

Defines a monad transformer used for defining routes
and using middleware.
-}

{-
TODO

* Route patterns (IE match a static path or a regex)
* Generalize from IO
* Errors!
* HTTP2 & HTTP2 server push
* HTTP params

-}

{-# LANGUAGE TupleSections, Rank2Types #-}

module Web.App.Monad.WebAppT
(
  -- * Monad Transformers
  WebAppT(..),
  -- * Typeclasses
  WebAppState(..),
  -- * Monadic Actions
  toApplication,
  middleware,
  route
) where

import Web.App.State
import Web.App.Monad.RouteT

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Concurrent.STM

import Data.List

import Network.Wai
import Network.HTTP.Types.Status (status404)
    
-- | Used to determine if a route can handle a request           
type Predicate = Request -> Bool
               
-- |Monad for defining routes & adding middleware.
newtype WebAppT s m a = WebAppT {
  runWebAppT :: [(Predicate, RouteT s m ())]
             -> [Middleware]
             -> m (a,[(Predicate, RouteT s m ())],[Middleware])
}

instance (WebAppState s, Functor m) => Functor (WebAppT s m) where
  fmap f m = WebAppT $ \r mw -> fmap (\(a, r', mw') -> (f a, r', mw')) $ runWebAppT m r mw

instance (WebAppState s, Monad m) => Applicative (WebAppT s m) where
  pure a = WebAppT $ \r mw -> pure (a, r, mw)
  (<*>) = ap
  -- WebAppT mf <*> WebAppT mx = WebAppT $ \r mw do
  --   ~(f, r', mw') <- mf r mw
  --   ~(x, r'', mw'') <- mx r' mw'
  --   return (f x, r'', mw'')

instance (WebAppState s, Monad m) => Monad (WebAppT s m) where
  m >>= k = WebAppT $ \r mw -> do
    ~(a, r', mw') <- runWebAppT m r mw
    ~(b, r'', mw'') <- runWebAppT (k a) r' mw'
    return (b, r'', mw'')
  fail msg = WebAppT $ \_ _ -> fail msg
  
instance (WebAppState s) => MonadTrans (WebAppT s) where
  lift m = WebAppT $ \r mw -> m >>= return . (,r,mw)

instance (WebAppState s, MonadIO m) => MonadIO (WebAppT s m) where
  liftIO = lift . liftIO
  
-- scottyAppT :: (Monad m, Monad n)
--            => (m Response -> IO Response) -- ^ Run monad 'm' into 'IO', called at each action.
--            -> ScottyT e m ()
--            -> n Application
-- scottyAppT runActionToIO defs = do
--     let s = execState (runS defs) def
--     let rapp req callback = runActionToIO (foldl (flip ($)) notFoundApp (routes s) req) >>= callback
--     return $ foldl (flip ($)) rapp (middlewares s)
  
-- |Turn a WebAppT computation into a WAI 'Application'.
toApplication :: (WebAppState s, Monad m) => TVar s -- ^ initial state
                                          -> (m Response -> IO Response) -- ^ action to run response into IO
                                          -> WebAppT s m () -- ^ a web app
                                          -> m Application -- ^ resulting 'Application'
toApplication tvar runToIO act = do
  ~(_,routes,middlewares) <- runWebAppT act [] []
  let rts = map (\(p,a) -> (p,evalRouteT tvar a)) routes -- [(Request -> Bool), (Request -> m Response)]
  return $ mkApp rts -- $ f (mkApp rts) middlewares
  where
    -- respondM :: (Monad m, Monad n) => (Response -> IO ResponseReceived) -> m Response -> n ResponseReceived
    -- respondM respond = lift respond
    f :: Application -> [Middleware] -> Application
    f app [] = app
    f app (x:xs) = f (x app) xs
   --  mkApp :: (Monad m) => [(Predicate, Request -> m Response)] -> Application
    mkApp routes req respond = case find (routePasses req) routes of
      Just route -> (runToIO $ routeResponse req route) >>= respond 
      Nothing -> respond $ responseLBS status404 [] "Not found."
      where routePasses r (p,_) = p r
            routeResponse r (_,a) = a r
    
    -- mkApp :: (WebAppState s) => TVar s -> [(Predicate, RouteT s m ())] -> Application
    -- mkApp st routes req respond = case find (routePasses req) routes of
    --   Just (_,ra) -> do
    --     --  resp <- evalRouteT st ra req -- TODO: FIXME m1 vs IO (col 31 - ra)
    --     --  respond resp
    --     respondM respond $ evalRouteT st ra req
    --   Nothing -> respond $ responseLBS status404 [] "Not found."
    --   where routePasses r (p,_) = p r
      
-- |Use a middleware
middleware :: (WebAppState s, Monad m) => Middleware -> WebAppT s m ()
middleware m = WebAppT $ \r mw -> return ((),r,mw ++ [m])

-- |Define a route
route :: (WebAppState s, Monad m) => Predicate -> RouteT s m () -> WebAppT s m ()
route p act = WebAppT $ \r mw -> return ((),r ++ [(p,act)],mw)