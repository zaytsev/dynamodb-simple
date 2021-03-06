{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns        #-}

module Database.DynamoDB.BatchRequest (
    putItemBatch
  , getItemBatch
  , deleteItemBatchByKey
) where

import           Control.Concurrent                  (threadDelay)
import           Control.Lens                        (at, ix, (.~), (^.), (^..))
import           Control.Monad                       (unless)
import           Control.Monad.Catch                 (throwM)
import           Control.Monad.IO.Class              (liftIO)
import           Data.Function                       ((&))
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as HMap
import           Data.List.NonEmpty                  (NonEmpty(..))
import           Data.Monoid                         ((<>))
import           Data.Proxy
import qualified Data.Text                           as T
import           Network.AWS
import qualified Network.AWS.DynamoDB.BatchGetItem   as D
import qualified Network.AWS.DynamoDB.BatchWriteItem as D
import qualified Network.AWS.DynamoDB.Types          as D

import           Database.DynamoDB.Class
import           Database.DynamoDB.Internal
import           Database.DynamoDB.Types



-- | Retry batch operation, until unprocessedItems is empty.
--
-- TODO: we should use exponential backoff; currently we use a simple 1-sec threadDelay
retryWriteBatch :: MonadAWS m => D.BatchWriteItem -> m ()
retryWriteBatch cmd = do
  rs <- send cmd
  let unprocessed = rs ^. D.bwirsUnprocessedItems
  unless (null unprocessed) $ do
      liftIO $ threadDelay 1000000
      retryWriteBatch (cmd & D.bwiRequestItems .~ unprocessed)

-- | Retry batch operation, until unprocessedItems is empty.
--
-- TODO: we should use exponential backoff; currently we use a simple 1-sec threadDelay
retryReadBatch :: MonadAWS m => D.BatchGetItem -> m (HashMap T.Text [HashMap T.Text D.AttributeValue])
retryReadBatch = go mempty
  where
    go previous cmd = do
      rs <- send cmd
      let unprocessed = rs ^. D.bgirsUnprocessedKeys
          result = HMap.unionWith (++) previous (rs ^. D.bgirsResponses)
      if | null unprocessed -> return result
         | otherwise -> do
              liftIO $ threadDelay 1000000
              go result (cmd & D.bgiRequestItems .~ unprocessed)

-- | Chunk list according to batch operation limit
chunkBatch :: Int -> [a] -> [NonEmpty a]
chunkBatch limit (splitAt limit -> (x:xs, rest)) = (x :| xs) : chunkBatch limit rest
chunkBatch _ _ = []

-- | Batch write into the database.
--
-- The batch is divided to 25-item chunks, each is sent and retried separately.
-- If a batch fails on dynamodb exception, it is raised.
--
-- Note: On exception, the information about which items were saved is unavailable
putItemBatch :: forall m a r. (MonadAWS m, DynamoTable a r) => [a] -> m ()
putItemBatch lst = mapM_ go (chunkBatch 25 lst)
  where
    go items = do
      let tblname = tableName (Proxy :: Proxy a)
          wrequests = fmap mkrequest items
          mkrequest item = D.writeRequest & D.wrPutRequest .~ Just (D.putRequest & D.prItem .~ gsEncode item)
          cmd = D.batchWriteItem & D.bwiRequestItems . at tblname .~ Just wrequests
      retryWriteBatch cmd


-- | Get batch of items.
getItemBatch :: forall m a r. (MonadAWS m, DynamoTable a r) => Consistency -> [PrimaryKey a r] -> m [a]
getItemBatch consistency lst = concat <$> mapM go (chunkBatch 100 lst)
  where
    go keys = do
        let tblname = tableName (Proxy :: Proxy a)
            wkaas = fmap (dKeyToAttr (Proxy :: Proxy a)) keys
            kaas = D.keysAndAttributes wkaas & D.kaaConsistentRead . consistencyL .~ consistency
            cmd = D.batchGetItem & D.bgiRequestItems . at tblname .~ Just kaas

        tbls <- retryReadBatch cmd
        mapM decoder (tbls ^.. ix tblname . traverse)
    decoder item =
        case dGsDecode item of
          Right res -> return res
          Left err -> throwM (DynamoException $ "Error decoding item: " <> err )

dDeleteRequest :: DynamoTable a r => Proxy a -> PrimaryKey a r -> D.DeleteRequest
dDeleteRequest p pkey = D.deleteRequest & D.drKey .~ dKeyToAttr p pkey

-- | Batch version of 'deleteItemByKey'.
--
-- Note: Because the requests are chunked, the information about which items
-- were deleted in case of exception is unavailable.
deleteItemBatchByKey :: forall m a r. (MonadAWS m, DynamoTable a r) => Proxy a -> [PrimaryKey a r] -> m ()
deleteItemBatchByKey p lst = mapM_ go (chunkBatch 25 lst)
  where
    go keys = do
      let tblname = tableName p
          wrequests = fmap mkrequest keys
          mkrequest key = D.writeRequest & D.wrDeleteRequest .~ Just (dDeleteRequest p key)
          cmd = D.batchWriteItem & D.bwiRequestItems . at tblname .~ Just wrequests
      retryWriteBatch cmd
