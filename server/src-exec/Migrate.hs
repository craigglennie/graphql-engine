module Migrate
  ( curCatalogVer
  , migrateCatalog
  )
where

import           Data.Time.Clock            (UTCTime)
import           Language.Haskell.TH.Syntax (Q, TExp, unTypeQ)

import           Hasura.Prelude
import           Hasura.RQL.DDL.Schema
import           Hasura.RQL.Types
import           Hasura.Server.Query

import qualified Data.Aeson                 as A
import qualified Data.Text                  as T
import qualified Data.Yaml.TH               as Y

import qualified Database.PG.Query          as Q

curCatalogVer :: T.Text
curCatalogVer = "23"

migrateMetadata
  :: ( MonadTx m
     , HasHttpManager m
     , CacheRWM m
     , UserInfoM m
     , MonadIO m
     , HasSQLGenCtx m
     )
  => Bool -> RQLQuery -> m ()
migrateMetadata buildSC rqlQuery = do
  -- Build schema cache from 'hdb_catalog' only if current
  -- metadata migration depends on metadata added in previous versions
  when buildSC $ buildSchemaCacheStrict
  -- run the RQL query to Migrate metadata
  void $ runQueryM rqlQuery

setAsSystemDefinedFor2 :: (MonadTx m) => m ()
setAsSystemDefinedFor2 =
  liftTx $ Q.catchE defaultTxErrorHandler $
  Q.multiQ [Q.sql|
            UPDATE hdb_catalog.hdb_table
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog'
             AND (  table_name = 'event_triggers'
                 OR table_name = 'event_log'
                 OR table_name = 'event_invocation_logs'
                 );
            UPDATE hdb_catalog.hdb_relationship
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog'
             AND (  table_name = 'event_triggers'
                 OR table_name = 'event_log'
                 OR table_name = 'event_invocation_logs'
                 );
           |]

setAsSystemDefinedFor5 :: (MonadTx m) => m ()
setAsSystemDefinedFor5 =
  liftTx $ Q.catchE defaultTxErrorHandler $
  Q.multiQ [Q.sql|
            UPDATE hdb_catalog.hdb_table
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog'
             AND table_name = 'remote_schemas';
           |]

setAsSystemDefinedFor8 :: (MonadTx m) => m ()
setAsSystemDefinedFor8 =
  liftTx $ Q.catchE defaultTxErrorHandler $
  Q.multiQ [Q.sql|
            UPDATE hdb_catalog.hdb_table
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog'
             AND (  table_name = 'hdb_function_agg'
                 OR table_name = 'hdb_function'
                 );
            UPDATE hdb_catalog.hdb_relationship
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog'
             AND  table_name = 'hdb_function_agg';
           |]

setAsSystemDefinedFor9 :: (MonadTx m) => m ()
setAsSystemDefinedFor9 =
  liftTx $ Q.catchE defaultTxErrorHandler $
  Q.multiQ [Q.sql|
            UPDATE hdb_catalog.hdb_table
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog'
             AND  table_name = 'hdb_version';
           |]

setAsSystemDefinedFor16 :: MonadTx m => m ()
setAsSystemDefinedFor16 =
  liftTx $ Q.catchE defaultTxErrorHandler $
  Q.multiQ [Q.sql|
            UPDATE hdb_catalog.hdb_table
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog'
             AND  table_name = 'hdb_query_collection';
           |]

getCatalogVersion
  :: (MonadTx m)
  => m T.Text
getCatalogVersion = do
  res <- liftTx $ Q.withQE defaultTxErrorHandler [Q.sql|
                SELECT version FROM hdb_catalog.hdb_version
                    |] () False
  return $ runIdentity $ Q.getRow res

from08To1 :: (MonadTx m) => m ()
from08To1 = liftTx $ Q.catchE defaultTxErrorHandler $ do
  Q.unitQ "ALTER TABLE hdb_catalog.hdb_relationship ADD COLUMN comment TEXT NULL" () False
  Q.unitQ "ALTER TABLE hdb_catalog.hdb_permission ADD COLUMN comment TEXT NULL" () False
  Q.unitQ "ALTER TABLE hdb_catalog.hdb_query_template ADD COLUMN comment TEXT NULL" () False
  Q.unitQ [Q.sql|
          UPDATE hdb_catalog.hdb_query_template
             SET template_defn =
                 json_build_object('type', 'select', 'args', template_defn->'select');
                |] () False

from1To2
  :: ( MonadTx m
     , HasHttpManager m
     , HasSQLGenCtx m
     , CacheRWM m
     , UserInfoM m
     , MonadIO m
     )
  => m ()
from1To2 = do
  -- Migrate database
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_1.sql")
  migrateMetadata False migrateMetadataFrom1
  -- Set as system defined
  setAsSystemDefinedFor2
  where
    migrateMetadataFrom1 =
      $(unTypeQ (Y.decodeFile "src-rsr/migrate_metadata_from_1.yaml" :: Q (TExp RQLQuery)))

from2To3 :: (MonadTx m) => m ()
from2To3 = liftTx $ Q.catchE defaultTxErrorHandler $ do
  Q.unitQ "ALTER TABLE hdb_catalog.event_triggers ADD COLUMN headers JSON" () False
  Q.unitQ "ALTER TABLE hdb_catalog.event_log ADD COLUMN next_retry_at TIMESTAMP" () False
  Q.unitQ "CREATE INDEX ON hdb_catalog.event_log (trigger_id)" () False
  Q.unitQ "CREATE INDEX ON hdb_catalog.event_invocation_logs (event_id)" () False

-- custom resolver
from4To5
  :: ( MonadTx m
     , HasHttpManager m
     , HasSQLGenCtx m
     , CacheRWM m
     , UserInfoM m
     , MonadIO m
     )
  => m ()
from4To5 = do
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_4_to_5.sql")
  migrateMetadata False migrateMetadataFrom4
  -- Set as system defined
  setAsSystemDefinedFor5
  where
    migrateMetadataFrom4 =
      $(unTypeQ (Y.decodeFile "src-rsr/migrate_metadata_from_4_to_5.yaml" :: Q (TExp RQLQuery)))


from3To4 :: (MonadTx m) => m ()
from3To4 = liftTx $ Q.catchE defaultTxErrorHandler $ do
  Q.unitQ "ALTER TABLE hdb_catalog.event_triggers ADD COLUMN configuration JSON" () False
  eventTriggers <- map uncurryEventTrigger <$> Q.listQ [Q.sql|
           SELECT e.name, e.definition::json, e.webhook, e.num_retries, e.retry_interval, e.headers::json
           FROM hdb_catalog.event_triggers e
           |] () False
  forM_ eventTriggers updateEventTrigger3To4
  Q.unitQ "ALTER TABLE hdb_catalog.event_triggers\
          \  DROP COLUMN definition\
          \, DROP COLUMN query\
          \, DROP COLUMN webhook\
          \, DROP COLUMN num_retries\
          \, DROP COLUMN retry_interval\
          \, DROP COLUMN headers" () False
  where
    uncurryEventTrigger (trn, Q.AltJ tDef, w, nr, rint, Q.AltJ headers) =
      EventTriggerConf trn tDef (Just w) Nothing (RetryConf nr rint Nothing) headers
    updateEventTrigger3To4 etc@(EventTriggerConf name _ _ _ _ _) = Q.unitQ [Q.sql|
                                         UPDATE hdb_catalog.event_triggers
                                         SET
                                         configuration = $1
                                         WHERE name = $2
                                         |] (Q.AltJ $ A.toJSON etc, name) True

from5To6 :: (MonadTx m) => m ()
from5To6 = liftTx $ do
  -- Migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_5_to_6.sql")
  return ()

from6To7 :: (MonadTx m) => m ()
from6To7 = liftTx $ do
  -- Migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_6_to_7.sql")
  return ()

from7To8
  :: ( MonadTx m
     , HasHttpManager m
     , HasSQLGenCtx m
     , CacheRWM m
     , UserInfoM m
     , MonadIO m
     )
  => m ()
from7To8 = do
  -- Migrate database
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_7_to_8.sql")
  -- Migrate metadata
  -- Building schema cache is required since this metadata migration
  -- involves in creating object relationship to hdb_catalog.hdb_table
  migrateMetadata True migrateMetadataFrom7
  setAsSystemDefinedFor8
  where
    migrateMetadataFrom7 =
      $(unTypeQ (Y.decodeFile "src-rsr/migrate_metadata_from_7_to_8.yaml" :: Q (TExp RQLQuery)))

-- alter hdb_version table and track it (telemetry changes)
from8To9
  :: ( MonadTx m
     , HasHttpManager m
     , HasSQLGenCtx m
     , CacheRWM m
     , UserInfoM m
     , MonadIO m
     )
  => m ()
from8To9 = do
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_8_to_9.sql")
  -- Migrate metadata
  migrateMetadata False migrateMetadataFrom8
  -- Set as system defined
  setAsSystemDefinedFor9
  where
    migrateMetadataFrom8 =
      $(unTypeQ (Y.decodeFile "src-rsr/migrate_metadata_from_8_to_9.yaml" :: Q (TExp RQLQuery)))

-- alter foreign keys on hdb_relationship and hdb_permission table to have ON UPDATE CASCADE
from9To10 :: (MonadTx m) => m ()
from9To10 = liftTx $ do
  -- Migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_9_to_10.sql")
  return ()

from10To11 :: (MonadTx m) => m ()
from10To11 = liftTx $ do
  -- Migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_10_to_11.sql")
  return ()

from11To12 :: (MonadTx m) => m ()
from11To12 = liftTx $ do
  -- Migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_11_to_12.sql")
  return ()

from12To13 :: (MonadTx m) => m ()
from12To13 = liftTx $ do
  -- Migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_12_to_13.sql")
  return ()

from13To14 :: (MonadTx m) => m ()
from13To14 = liftTx $ do
  -- Migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_13_to_14.sql")
  return ()

from14To15 :: (MonadTx m) => m ()
from14To15 = liftTx $ do
  -- Migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_14_to_15.sql")
  return ()

from15To16
  :: ( MonadTx m
     , HasHttpManager m
     , HasSQLGenCtx m
     , CacheRWM m
     , UserInfoM m
     , MonadIO m
     )
  => m ()
from15To16 = do
  -- Migrate database
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_15_to_16.sql")
  -- Migrate metadata
  migrateMetadata False migrateMetadataFrom13
  -- Set as system defined
  setAsSystemDefinedFor16
  where
    migrateMetadataFrom13 =
      $(unTypeQ (Y.decodeFile "src-rsr/migrate_metadata_from_15_to_16.yaml" :: Q (TExp RQLQuery)))

from16To17 :: MonadTx m => m ()
from16To17 =
  liftTx $ Q.catchE defaultTxErrorHandler $
  Q.multiQ [Q.sql|
            UPDATE hdb_catalog.hdb_table
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog'
             AND  table_name = 'hdb_allowlist';
           |]

from17To18 :: MonadTx m => m ()
from17To18 =
  liftTx $ Q.catchE defaultTxErrorHandler $
  Q.multiQ [Q.sql|
            DELETE FROM hdb_catalog.hdb_table
            WHERE table_schema = 'hdb_catalog'
              AND table_name = 'hdb_query_template';
            DROP table hdb_catalog.hdb_query_template
           |]

from18To19 :: MonadTx m => m ()
from18To19 = do
  -- Migrate database
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_18_to_19.sql")
  return ()

from19To20 :: (MonadTx m) => m ()
from19To20 = do
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_19_to_20.sql")
  pure ()

from20To21 :: (MonadTx m) => m ()
from20To21 = liftTx $ Q.catchE defaultTxErrorHandler $ do
  Q.unitQ "CREATE INDEX ON hdb_catalog.event_log (locked)" () False

from21To22 :: (MonadTx m) => m ()
from21To22 = do
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_21_to_22.sql")
  pure ()

from22To23 :: (MonadTx m) => m ()
from22To23 = do
  Q.Discard () <- liftTx $ Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_22_to_23.sql")
  pure ()

migrateCatalog
  :: ( MonadTx m
     , CacheRWM m
     , MonadIO m
     , UserInfoM m
     , HasHttpManager m
     , HasSQLGenCtx m
     )
  => UTCTime -> m String
migrateCatalog migrationTime = migrateFrom =<< getCatalogVersion
  where
    migrateFrom previousVersion
      | previousVersion == curCatalogVer =
          return $ "already at the latest version. current version: " <> show curCatalogVer
      | [] <- neededMigrations =
          throw400 NotSupported $ "unsupported version : " <> previousVersion
      | otherwise =
          traverse_ snd neededMigrations >> postMigrate
      where
        neededMigrations = dropWhile ((/= previousVersion) . fst) migrations
        migrations =
          [ ("0.8", from08To1)
          , ("1", from1To2)
          , ("2", from2To3)
          , ("3", from3To4)
          , ("4", from4To5)
          , ("5", from5To6)
          , ("6", from6To7)
          , ("7", from7To8)
          , ("8", from8To9)
          , ("9", from9To10)
          , ("10", from10To11)
          , ("11", from11To12)
          , ("12", from12To13)
          , ("13", from13To14)
          , ("14", from14To15)
          , ("15", from15To16)
          , ("16", from16To17)
          , ("17", from17To18)
          , ("18", from18To19)
          , ("19", from19To20)
          , ("20", from20To21)
          , ("21", from21To22)
          , ("22", from22To23)
          ]

    postMigrate = do
       -- update the catalog version
       updateVersion
       -- try building the schema cache
       buildSchemaCacheStrict
       return $ "successfully migrated to " ++ show curCatalogVer

    updateVersion =
      liftTx $ Q.unitQE defaultTxErrorHandler [Q.sql|
                UPDATE "hdb_catalog"."hdb_version"
                   SET "version" = $1,
                       "upgraded_on" = $2
                    |] (curCatalogVer, migrationTime) False
