{-# LANGUAGE TypeSynonymInstances, OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Yesod.Core.Json
    ( -- * Convert from a JSON value
      defaultLayoutJson
    , jsonToRepJson
    , returnJson
#if MIN_VERSION_aeson(0, 11, 0)
    , returnJsonEncoding
#endif
    , provideJson

      -- * Convert to a JSON value
    , parseJsonBody
    , parseCheckJsonBody
    , parseJsonBody_
    , requireJsonBody
    , requireCheckJsonBody

      -- * Produce JSON values
    , J.Value (..)
    , J.ToJSON (..)
    , J.FromJSON (..)
    , array
    , object
    , (.=)
    , (J..:)

      -- * Convenience functions
    , jsonOrRedirect
#if MIN_VERSION_aeson(0, 11, 0)
    , jsonEncodingOrRedirect
#endif
    , acceptsJson
    ) where

import Yesod.Core.Handler (HandlerT, getRequest, invalidArgs, redirect, selectRep, provideRep, rawRequestBody, ProvidedRep, lookupHeader)
import Control.Monad.Trans.Writer (Writer)
import Data.Monoid (Endo)
import Yesod.Core.Types (reqAccept)
import Yesod.Core.Class.Yesod (defaultLayoutJson)
import Yesod.Core.Class.Handler
import Yesod.Routes.Class
import qualified Data.Aeson as J
import qualified Data.Aeson.Parser as JP
import Data.Aeson ((.=), object)
import Data.Conduit.Attoparsec (sinkParser)
import Data.Text (pack)
import qualified Data.Vector as V
import Data.Conduit
import Data.Conduit.Lift
import qualified Data.ByteString.Char8 as B8
import Data.Maybe (listToMaybe)
import Control.Monad (liftM)

-- | Provide both an HTML and JSON representation for a piece of
-- data, using the default layout for the HTML output
-- ('defaultLayout').
--
-- @since 0.3.0
defaultLayoutJson :: (Yesod site, J.ToJSON a)
                  => WidgetT site IO ()  -- ^ HTML
                  -> HandlerT site IO a  -- ^ JSON
                  -> HandlerT site IO TypedContent
defaultLayoutJson w json = selectRep $ do
    provideRep $ defaultLayout w
#if MIN_VERSION_aeson(0, 11, 0)
    provideRep $ fmap J.toEncoding json
#else
    provideRep $ fmap J.toJSON json
#endif

-- | Wraps a data type in a 'RepJson'.  The data type must
-- support conversion to JSON via 'J.ToJSON'.
--
-- @since 0.3.0
jsonToRepJson :: (Monad m, J.ToJSON a) => a -> m J.Value
jsonToRepJson = return . J.toJSON
{-# DEPRECATED jsonToRepJson "Use returnJson instead" #-}

-- | Convert a value to a JSON representation via aeson\'s 'J.toJSON' function.
--
-- @since 1.2.1
returnJson :: (Monad m, J.ToJSON a) => a -> m J.Value
returnJson = return . J.toJSON

#if MIN_VERSION_aeson(0, 11, 0)
-- | Convert a value to a JSON representation via aeson\'s 'J.toEncoding' function.
--
-- @since 1.4.21
returnJsonEncoding :: (Monad m, J.ToJSON a) => a -> m J.Encoding
returnJsonEncoding = return . J.toEncoding
#endif

-- | Provide a JSON representation for usage with 'selectReps', using aeson\'s
-- 'J.toJSON' (aeson >= 0.11: 'J.toEncoding') function to perform the conversion.
--
-- @since 1.2.1
provideJson :: (Monad m, J.ToJSON a) => a -> Writer (Endo [ProvidedRep m]) ()
#if MIN_VERSION_aeson(0, 11, 0)
provideJson = provideRep . return . J.toEncoding
#else
provideJson = provideRep . return . J.toJSON
#endif

-- | Parse the request body to a data type as a JSON value.  The
-- data type must support conversion from JSON via 'J.FromJSON'.
-- If you want the raw JSON value, just ask for a @'J.Result'
-- 'J.Value'@.
--
-- Note that this function will consume the request body. As such, calling it
-- twice will result in a parse error on the second call, since the request
-- body will no longer be available.
--
-- @since 0.3.0
parseJsonBody :: (MonadHandler m, J.FromJSON a) => m (J.Result a)
parseJsonBody = do
    eValue <- rawRequestBody $$ runCatchC (sinkParser JP.value')
    return $ case eValue of
        Left e -> J.Error $ show e
        Right value -> J.fromJSON value

-- | Same as 'parseJsonBody', but ensures that the mime type indicates
-- JSON content.
parseCheckJsonBody :: (MonadHandler m, J.FromJSON a) => m (J.Result a)
parseCheckJsonBody = do
    mct <- lookupHeader "content-type"
    case fmap (B8.takeWhile (/= ';')) mct of
        Just "application/json" -> parseJsonBody
        _ -> return $ J.Error $ "Non-JSON content type: " ++ show mct

-- | Same as 'parseJsonBody', but return an invalid args response on a parse
-- error.
parseJsonBody_ :: (MonadHandler m, J.FromJSON a) => m a
parseJsonBody_ = requireJsonBody
{-# DEPRECATED parseJsonBody_ "Use requireJsonBody instead" #-}

-- | Same as 'parseJsonBody', but return an invalid args response on a parse
-- error.
requireJsonBody :: (MonadHandler m, J.FromJSON a) => m a
requireJsonBody = do
    ra <- parseJsonBody
    case ra of
        J.Error s -> invalidArgs [pack s]
        J.Success a -> return a

-- | Same as 'requireJsonBody', but ensures that the mime type
-- indicates JSON content.
requireCheckJsonBody :: (MonadHandler m, J.FromJSON a) => m a
requireCheckJsonBody = do
    ra <- parseCheckJsonBody
    case ra of
        J.Error s -> invalidArgs [pack s]
        J.Success a -> return a

-- | Convert a list of values to an 'J.Array'.
array :: J.ToJSON a => [a] -> J.Value
array = J.Array . V.fromList . map J.toJSON

-- | jsonOrRedirect simplifies the scenario where a POST handler sends a different
-- response based on Accept headers:
--
--     1. 200 with JSON data if the client prefers
--     @application\/json@ (e.g. AJAX, see 'acceptsJSON').
--
--     2. 3xx otherwise, following the PRG pattern.
jsonOrRedirect :: (MonadHandler m, J.ToJSON a)
               => Route (HandlerSite m) -- ^ Redirect target
               -> a            -- ^ Data to send via JSON
               -> m J.Value
jsonOrRedirect = jsonOrRedirect' J.toJSON

#if MIN_VERSION_aeson(0, 11, 0)
-- | jsonEncodingOrRedirect simplifies the scenario where a POST handler sends a different
-- response based on Accept headers:
--
--     1. 200 with JSON data if the client prefers
--     @application\/json@ (e.g. AJAX, see 'acceptsJSON').
--
--     2. 3xx otherwise, following the PRG pattern.
-- @since 1.4.21
jsonEncodingOrRedirect :: (MonadHandler m, J.ToJSON a)
            => Route (HandlerSite m) -- ^ Redirect target
            -> a            -- ^ Data to send via JSON
            -> m J.Encoding
jsonEncodingOrRedirect = jsonOrRedirect' J.toEncoding
#endif

jsonOrRedirect' :: MonadHandler m
            => (a -> b)
            -> Route (HandlerSite m) -- ^ Redirect target
            -> a            -- ^ Data to send via JSON
            -> m b
jsonOrRedirect' f r j = do
    q <- acceptsJson
    if q then return (f j)
         else redirect r

-- | Returns @True@ if the client prefers @application\/json@ as
-- indicated by the @Accept@ HTTP header.
acceptsJson :: MonadHandler m => m Bool
acceptsJson =  (maybe False ((== "application/json") . B8.takeWhile (/= ';'))
            .  listToMaybe
            .  reqAccept)
           `liftM` getRequest
