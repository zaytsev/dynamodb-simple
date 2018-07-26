{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE TypeFamilies       #-}

module Database.DynamoDB.Migration (
  runMigration
) where

import           Control.Arrow                      (first)
import           Control.Concurrent                 (threadDelay)
import           Control.Lens                       (_1, set, view, (%~), (.~),
                                                     (^.), (^..), (^?), _Just)
import           Control.Monad                      (unless, void, when)
import           Control.Monad.Catch                (throwM)
import           Control.Monad.IO.Class             (liftIO)
import           Control.Monad.Loops                (whileM_)
import           Control.Monad.Trans.AWS            (AWSConstraint)
import           Data.Bool                          (bool)
import           Data.Foldable                      (toList)
import           Data.Function                      ((&))
import qualified Data.HashMap.Strict                as HMap
import           Data.List                          (nub, (\\))
import           Data.Maybe                         (mapMaybe, fromMaybe)
import           Data.Monoid                        ((<>))
import           Data.Proxy
import qualified Data.Set                           as Set
import qualified Data.Text                          as T
import           Data.Text.Encoding                 (encodeUtf8Builder)
import           Generics.SOP
import           Network.AWS
import qualified Network.AWS.DynamoDB.CreateTable   as D
import qualified Network.AWS.DynamoDB.DescribeTable as D
import qualified Network.AWS.DynamoDB.Types         as D
import qualified Network.AWS.DynamoDB.UpdateTable   as D

import           Database.DynamoDB.Class
import           Database.DynamoDB.Types

getTableDescription :: MonadAWS m => T.Text -> m D.TableDescription
getTableDescription tblname = do
  rs <- send (D.describeTable tblname)
  case rs ^? D.drsTable . _Just of
      Just descr -> return descr
      Nothing -> throwM (DynamoException "getTableStatus - did not get correct data")

-- | Periodically check state of table, until it is ACTIVE
waitUntilTableActive :: forall r m. (AWSConstraint r m, MonadAWS m) => T.Text -> Bool -> m ()
waitUntilTableActive name checkindex =
    whileM_ tableIsNotActive $ do
        logmsg Info $ "Waiting for table " <> name <> " and its indices to become active"
        liftIO $ threadDelay 5000000
  where
    tableIsNotActive :: m Bool
    tableIsNotActive = do
        descr <- getTableDescription name
        status <- maybe (throwM (DynamoException "Missing table status")) return (descr ^. D.tdTableStatus)
        let idxstatus = descr ^.. D.tdGlobalSecondaryIndexes . traverse . D.gsidIndexStatus . _Just
        if | checkindex -> return (status /= D.TSActive || any (/= D.ISActive) idxstatus)
           | otherwise -> return (status /= D.TSActive)

-- | Delete specified indices from the database
deleteIndices :: forall m. MonadAWS m => T.Text -> [T.Text] -> m ()
deleteIndices tblname indices = do
  let idxupdates = map (\name -> set D.gsiuDelete (Just $ D.deleteGlobalSecondaryIndexAction name) D.globalSecondaryIndexUpdate) indices
      cmd = D.updateTable tblname & D.utGlobalSecondaryIndexUpdates .~ idxupdates
  void $ send cmd

-- | Update table with specified new indices
createIndices :: forall m. MonadAWS m => D.CreateTable -> [D.GlobalSecondaryIndex] -> m ()
createIndices table indices = do
    let tblname = table ^. D.ctTableName
        idxupdates = map (\idx -> set D.gsiuCreate (Just $ mkidx idx) D.globalSecondaryIndexUpdate) indices
        cmd = D.updateTable tblname & D.utGlobalSecondaryIndexUpdates .~ idxupdates
                                    & D.utAttributeDefinitions .~ (table ^. D.ctAttributeDefinitions)
    void $ send cmd
  where
    mkidx :: D.GlobalSecondaryIndex -> D.CreateGlobalSecondaryIndexAction
    mkidx idx = D.createGlobalSecondaryIndexAction (idx ^. D.gsiIndexName) (idx ^. D.gsiKeySchema)
                                                   (idx ^. D.gsiProjection) (idx ^. D.gsiProvisionedThroughput)

-- | Compare intersection of new and old indexes and find inconsistent ones
findInconsistentIdxes :: [D.GlobalSecondaryIndex] -> [D.GlobalSecondaryIndexDescription] -> [D.GlobalSecondaryIndex]
findInconsistentIdxes newidxes oldidxes =
    map fst $ filter hasConflict $ toList $ HMap.intersectionWith (,) newmap oldmap
  where
    newmap = HMap.fromList $ map (\idx -> (idx ^. D.gsiIndexName, idx)) newidxes
    oldmap = HMap.fromList $ mapMaybe (\idx -> (,idx) <$> idx ^. D.gsidIndexName) oldidxes
    --
    hasConflict (newidx, oldix) = not (projectionOk newidx oldix && keysOk newidx oldix)
    keysOk newidx oldidx = Just (newidx ^. D.gsiKeySchema) == oldidx ^. D.gsidKeySchema
    -- Assume the indices were created by this module and we want them exactly the same
    projectionOk newidx oldidx =
       -- Allow the index to have more fields than we know about
        newprojtype == Just D.PTKeysOnly || (newprojtype == oldprojtype && newkeys `Set.isSubsetOf` oldkeys)
      where
          newprojtype = newidx ^? D.gsiProjection . D.pProjectionType . _Just
          oldprojtype = oldidx ^? D.gsidProjection . _Just . D.pProjectionType . _Just
          newkeys = Set.fromList $ newidx ^.. D.gsiProjection . D.pNonKeyAttributes . _Just . traverse
          oldkeys = Set.fromList $ oldidx ^.. D.gsidProjection . _Just . D.pNonKeyAttributes . _Just . traverse

-- | Verbatim copy of findInconsistentIdxes, but changed to localSecondaryIndex structure
findInconsistentLocIdxes :: [D.LocalSecondaryIndex] -> [D.LocalSecondaryIndexDescription] -> [T.Text]
findInconsistentLocIdxes newidxes oldidxes =
    map (view (_1 . D.lsiIndexName)) $ filter hasConflict $ toList $ HMap.intersectionWith (,) newmap oldmap
  where
    newmap = HMap.fromList $ map (\idx -> (idx ^. D.lsiIndexName, idx)) newidxes
    oldmap = HMap.fromList $ mapMaybe (\idx -> (,idx) <$> idx ^. D.lsidIndexName) oldidxes
    --
    hasConflict (newidx, oldix) = not (projectionOk newidx oldix && keysOk newidx oldix)
    keysOk newidx oldidx = Just (newidx ^. D.lsiKeySchema) == oldidx ^. D.lsidKeySchema
    -- Assume the indices were created by this module and we want them exactly the same
    projectionOk newidx oldidx =
        newprojtype == Just D.PTKeysOnly || (newprojtype == oldprojtype && newkeys `Set.isSubsetOf` oldkeys)
      where
          newprojtype = newidx ^? D.lsiProjection . D.pProjectionType . _Just
          oldprojtype = oldidx ^? D.lsidProjection . _Just . D.pProjectionType . _Just
          newkeys = Set.fromList $ newidx ^.. D.lsiProjection . D.pNonKeyAttributes . _Just . traverse
          oldkeys = Set.fromList $ oldidx ^.. D.lsidProjection . _Just . D.pNonKeyAttributes . _Just . traverse


-- | Compare indexes and return list of indices to delete and to create; indices to recreate are included
compareIndexes :: D.CreateTable -> D.TableDescription -> ([T.Text], [D.GlobalSecondaryIndex])
compareIndexes tabledef descr = (todelete, tocreate)
  where
    newidxlist = tabledef ^. D.ctGlobalSecondaryIndexes
    oldidxlist = descr ^. D.tdGlobalSecondaryIndexes
    newidxnames = newidxlist ^.. traverse . D.gsiIndexName
    oldidxnames = oldidxlist ^.. traverse . D.gsidIndexName . _Just
    --
    recreate = findInconsistentIdxes newidxlist oldidxlist
    todelete = map (view D.gsiIndexName) recreate ++ (oldidxnames \\ newidxnames)
    tocreate = recreate ++ filter (\idx -> idx ^. D.gsiIndexName `notElem` oldidxnames) newidxlist

compareLocalIndexes :: MonadAWS m => D.CreateTable -> D.TableDescription -> m ()
compareLocalIndexes tabledef descr = do
  let newidxlist = tabledef ^. D.ctLocalSecondaryIndexes
      oldidxlist = descr ^. D.tdLocalSecondaryIndexes
      newidxnames = newidxlist ^.. traverse . D.lsiIndexName
      oldidxnames = oldidxlist ^.. traverse . D.lsidIndexName . _Just
      missing = filter (`notElem` oldidxnames) newidxnames
  unless (null missing) $
      throwM (DynamoException ("Missing local secondary indexes: " <> T.intercalate "," missing))
  let inconsistent = findInconsistentLocIdxes newidxlist oldidxlist
  unless (null inconsistent) $
      throwM (DynamoException ("Inconsistent local index settings (projection/types): "
                                <> T.intercalate "," inconsistent))

-- | Change streaming settings on a table
changeStream :: (AWSConstraint r m, MonadAWS m)
    => T.Text -> Maybe D.StreamSpecification -> Maybe D.StreamSpecification -> m ()
changeStream _ Nothing Nothing = return ()
changeStream tblname (Just _) Nothing = do
    logmsg Info "Disabling streaming."
    waitUntilTableActive tblname False
    let strspec = D.streamSpecification & D.ssStreamEnabled .~ Just False
        cmd = D.updateTable tblname & D.utStreamSpecification .~ Just strspec
    void (send cmd)
changeStream tblname Nothing (Just new) = do
    waitUntilTableActive tblname False
    logmsg Info "Enabling streaming."
    let cmd = D.updateTable tblname & D.utStreamSpecification .~ Just new
    void (send cmd)
changeStream tblname (Just old) (Just new) = do
    changeStream tblname (Just old) Nothing
    changeStream tblname Nothing (Just new)


-- | Main table migration code
tryMigration :: (AWSConstraint r m, MonadAWS m) => D.CreateTable -> D.TableDescription -> m ()
tryMigration tabledef descr = do
    -- Check key schema on the main table, fail if it changed.
    let tblkeys = tabledef ^. D.ctKeySchema
        oldtblkeys = descr ^. D.tdKeySchema
    when (Just tblkeys /= oldtblkeys) $ do
        let msg = "Table " <> tblname <> " hash/range key mismatch; new table: "
                    <> T.pack (show tblkeys) <> ", old table: " <> T.pack (show oldtblkeys)
        logmsg Error msg
        throwM (DynamoException msg)

    -- Check that types of key attributes are the same
    unless (null conflictTableAttrs) $ do
        let msg = "Table or index " <> tblname <> " has conflicting attribute key types: " <> T.pack (show conflictTableAttrs)
        logmsg Error msg
        throwM (DynamoException msg)

    -- Check that local indexes are in sync with the settings. Fails if inconsistent.
    compareLocalIndexes tabledef descr

    -- Adjust indexes
    let (todelete, tocreate) = compareIndexes tabledef descr
    unless (null todelete) $ do
        waitUntilTableActive tblname False
        logmsg Info $ "Deleting indices: " <> T.intercalate "," todelete
        deleteIndices tblname todelete
    unless (null tocreate) $ do
        waitUntilTableActive tblname True
        logmsg Info $ "Create new indices: " <> T.intercalate "," (tocreate ^.. traverse . D.gsiIndexName)
        createIndices tabledef tocreate
    -- Check streaming settings
    when (tabledef ^. D.ctStreamSpecification /= descr ^. D.tdStreamSpecification) $
        changeStream tblname (descr ^. D.tdStreamSpecification) (tabledef ^. D.ctStreamSpecification)
    -- Done
    logmsg Info $ "Table " <> tblname <> " schema check done."
  where
    tblname = tabledef ^. D.ctTableName
    -- Compare tableattribute types from old and new tables
    conflictTableAttrs =
        let attrToTup = (,) <$> view D.adAttributeName <*> view D.adAttributeType
            attrdefs = HMap.fromList $ map attrToTup (tabledef ^. D.ctAttributeDefinitions)
            olddefs = HMap.fromList $ map attrToTup (descr ^. D.tdAttributeDefinitions)
            commonkeys = HMap.intersectionWith (,) attrdefs olddefs
        in
            HMap.toList $ HMap.filter (uncurry (/=)) commonkeys


logmsg :: AWSConstraint r m => LogLevel -> T.Text -> m ()
logmsg level text = do
  logger <- view envLogger
  liftIO $ logger level (encodeUtf8Builder text)

prettyTableInfo :: D.CreateTable -> T.Text
prettyTableInfo tblinfo =
    tblname <> "(" <> tkeys <> ")" <> indexinfo idxlist
  where
    tblname = tblinfo ^. D.ctTableName
    tkeys = T.intercalate "," $ tblinfo ^.. (D.ctKeySchema . traverse . D.kseAttributeName)
    idxlist = tblinfo ^. D.ctGlobalSecondaryIndexes
    indexinfo [] = ""
    indexinfo lst = " with indexes: " <> T.intercalate ", " (map printidx lst)
    printidx idx = idx ^. D.gsiIndexName <> "(" <> ikeys idx <> ")"
    ikeys idx = T.intercalate "," $ idx ^.. (D.gsiKeySchema . traverse . D.kseAttributeName)

createOrMigrate :: (AWSConstraint r m, MonadAWS m) => D.CreateTable -> m ()
createOrMigrate tabledef = do
    let tblname = tabledef ^. D.ctTableName
    ers <- trying _ServiceError $ send (D.describeTable tblname)
    case ers of
      Left _ -> do
          logmsg Info ("Creating table: " <> prettyTableInfo tabledef)
          void $ send tabledef -- table doesn't exist, create a new one
          waitUntilTableActive tblname True
      Right rs
        | Just descr <- rs ^. D.drsTable -> do
            logmsg Info ("Table " <> tblname <> " alread exists, checking schema.")
            tryMigration tabledef descr
        | otherwise -> throwM (DynamoException "Didn't receive correct table description.")

runMigration :: (TableCreate table r, MonadAWS m, Code table ~ '[ hash ': range ': rest ])
  =>  Proxy table
  -> [D.ProvisionedThroughput -> (D.GlobalSecondaryIndex, [D.AttributeDefinition])]
  -> [(D.LocalSecondaryIndex, [D.AttributeDefinition])]
  -> HMap.HashMap T.Text D.ProvisionedThroughput
  -> Maybe D.StreamViewType
  -> m ()
runMigration ptbl globindices' locindices provisionMap stream =
  liftAWS $ do
      let tbl = createTable ptbl (getProv (tableName ptbl))
          globindices = map (first adjustProv . ($ defaultprov)) globindices'
          idxattrs = concatMap snd globindices ++ concatMap snd locindices
      -- Bug in amazonka, we must not set the attribute if it is empty
      -- see https://github.com/brendanhay/amazonka/issues/332
      let final = tbl & bool (D.ctGlobalSecondaryIndexes .~ map fst globindices) id (null globindices)
                      & bool (D.ctLocalSecondaryIndexes .~ map fst locindices) id (null locindices)
                      & D.ctAttributeDefinitions %~ (nub . (<> idxattrs))
                      & addStream stream
      createOrMigrate final
  where
    getProv name = fromMaybe defaultprov (HMap.lookup name provisionMap)
    defaultprov = D.provisionedThroughput 5 5
    adjustProv idx = idx & (D.gsiProvisionedThroughput .~ getProv (idx ^. D.gsiIndexName))
    addStream Nothing = id
    addStream (Just stype) =
      let strspec = D.streamSpecification & D.ssStreamEnabled .~ Just True
                                          & D.ssStreamViewType .~ Just stype
      in D.ctStreamSpecification .~ Just strspec
