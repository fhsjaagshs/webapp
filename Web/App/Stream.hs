{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
module Web.App.Stream
(
  Stream(..),
  stream
)
where
  
import Network.Wai (StreamingBody)
import Blaze.ByteString.Builder
import qualified Data.ByteString.Char8 as B
import Data.String

-- |An HTTP response body stream.
newtype Stream = Stream { runStream :: StreamingBody }

instance Show Stream where
  show = const "<Stream>"
  
instance IsString Stream where
  fromString = stream . fromByteString . B.pack
  
instance Monoid Stream where
  mempty = Stream $ \_ _ -> return ()
  mappend (Stream a) (Stream b) = Stream $ \w f -> a w f >> b w f
  
-- TODO: Monad classes?

-- |Stream a Blaze ByteString Builder.
stream :: Builder -> Stream
stream b = Stream $ \w f -> w b >> f
