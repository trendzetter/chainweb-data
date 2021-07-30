{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Chainweb.Backfill
( backfill
, lookupPlan
) where


import           BasePrelude hiding (insert, range, second)

import           Chainweb.Api.BlockHeader
import           Chainweb.Api.ChainId (ChainId(..))
import           Chainweb.Api.NodeInfo
import           Chainweb.Database
import           Chainweb.Env
import           Chainweb.Lookups
import           Chainweb.Worker
import           ChainwebData.Backfill
import           ChainwebData.Genesis
import           ChainwebData.Types
import           ChainwebDb.Types.Block

import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (race_)
import           Control.Concurrent.STM
import           Control.Scheduler hiding (traverse_)

import           Data.ByteString.Lazy (ByteString)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Pool as P
import qualified Data.Vector as V
import           Data.Witherable.Class (wither)


import           System.Logger.Types hiding (logg)

import           Database.Beam hiding (insert)
import           Database.Beam.Postgres

---

backfill :: Env -> BackfillArgs -> IO ()
backfill env args = do
  ecut <- queryCut env
  case ecut of
    Left e -> do
      let logg = _env_logger env
      logg Error "Error querying cut"
      logg Info $ fromString $ show e
    Right cutBS -> backfillBlocksCut env args cutBS

backfillBlocksCut :: Env -> BackfillArgs -> ByteString -> IO ()
backfillBlocksCut env args cutBS = do
  let curHeight = fromIntegral $ cutMaxHeight cutBS
      cids = atBlockHeight curHeight allCids
  counter <- newIORef 0
  sampler <- newIORef 0
  mins <- minHeights cids pool
  let count = M.size mins
  if count /= length cids
    then do
      logg Error $ fromString $ printf "%d chains have block data, but we expected %d.\n" count (length cids)
      logg Error $ fromString $ printf "Please run a 'listen' first, and ensure that each chain has a least one block.\n"
      logg Error $ fromString $ printf "That should take about a minute, after which you can rerun 'backfill' separately.\n"
      exitFailure
    else do
      logg Info $ fromString $ printf "Beginning backfill on %d chains.\n" count
      let strat = case delay of
                    Nothing -> Par'
                    Just _ -> Seq
      blockQueue <- newTBQueueIO 20
      race_ (progress logg counter $ foldl' (+) 0 mins)
        $ traverseMapConcurrently_ Par' (\k -> traverseConcurrently_ strat (f blockQueue counter sampler) . map (toTriple k)) $ toChainMap $ lookupPlan genesisInfo mins
  where
    traverseMapConcurrently_ comp g m =
      withScheduler_ comp $ \s -> scheduleWork s $ void $ M.traverseWithKey (\k -> scheduleWork s . void . g k) m
    delay = _backfillArgs_delayMicros args
    toTriple k (v1,v2) = (k,v1,v2)
    toChainMap = M.fromListWith (flip (<>)) . map (\(cid,l,h) -> (cid,[(l,h)]))
    logg = _env_logger env
    pool = _env_dbConnPool env
    allCids = _env_chainsAtHeight env
    genesisInfo = mkGenesisInfo $ _env_nodeInfo env
    delayFunc =
      case delay of
        Nothing -> pure ()
        Just d -> threadDelay d
    f :: TBQueue (V.Vector BlockHeader) -> IORef Int -> IORef Int -> (ChainId, Low, High) -> IO ()
    f blockQueue count sampler range = do
      headersBetween env range >>= \case
        Left e -> logg Error $ fromString $ printf "ApiError for range %s: %s\n" (show range) (show e)
        Right [] -> logg Error $ fromString $ printf "headersBetween: %s\n" $ show range
        Right hs -> do
          let vs = V.fromList hs
          atomically (tryReadTBQueue blockQueue) >>= \case
            Nothing -> atomically $ writeTBQueue blockQueue vs
            Just q -> do
              writeBlocks env pool False count sampler (V.toList q)
              atomically $ writeTBQueue blockQueue vs
      delayFunc

-- | For all blocks written to the DB, find the shortest (in terms of block
-- height) for each chain.
minHeights :: [ChainId] -> P.Pool Connection -> IO (Map ChainId Int)
minHeights cids pool = M.fromList <$> wither selectMinHeight cids
  where
    -- | Get the current minimum height of any block on some chain.
    selectMinHeight :: ChainId -> IO (Maybe (ChainId, Int))
    selectMinHeight cid_@(ChainId cid) = fmap (fmap (\bh -> (cid_, fromIntegral $ _block_height bh)))
      $ P.withResource pool
      $ \c -> runBeamPostgres c
      $ runSelectReturningOne
      $ select
      $ limit_ 1
      $ orderBy_ (asc_ . _block_height)
      $ filter_ (\b -> _block_chainId b ==. val_ (fromIntegral cid))
      $ all_ (_cddb_blocks database)
