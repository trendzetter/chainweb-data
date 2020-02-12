{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}

module Chainweb.Update ( updates ) where

import           BasePrelude hiding (delete, insert)
import           Chainweb.Api.BlockPayload
import           Chainweb.Api.ChainwebMeta
import           Chainweb.Api.Hash
import           Chainweb.Api.MinerData
import           Chainweb.Api.PactCommand
import           Chainweb.Api.Payload
import qualified Chainweb.Api.Transaction as CW
import           Chainweb.Database
import           Chainweb.Env
import           ChainwebDb.Types.Block
import           ChainwebDb.Types.DbHash
import           ChainwebDb.Types.Header
import           ChainwebDb.Types.Miner
import           ChainwebDb.Types.Transaction
import           Control.Monad.Trans.Maybe
import           Control.Scheduler (Comp(..), traverseConcurrently_)
import           Data.Aeson (decode')
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Database.Beam
import           Database.Beam.Sqlite
import           Database.SQLite.Simple (Connection)
import           Network.HTTP.Client hiding (Proxy)

---

-- | A wrapper to massage some types below.
data Quad = Quad !BlockPayload !Block !Miner ![Transaction]

updates :: Env -> IO ()
updates e@(Env _ c _ _) = do
  hs <- runBeamSqlite c . runSelectReturningList $ select prd
  traverseConcurrently_ (ParN 8) (\h -> lookups e h >>= writes c h) hs
  where
    prd = all_ $ headers database

-- | Write a Block and its Transactions to the database. Also writes the Miner
-- if it hasn't already been via some other block.
writes :: Connection -> Header -> Maybe Quad -> IO ()
writes c h (Just q) = writes' c h q
writes _ h _ = T.putStrLn $ "[FAIL] Payload fetch for Block: " <> unDbHash (_header_hash h)

writes' :: Connection -> Header -> Quad -> IO ()
writes' c h (Quad _ b m ts) = runBeamSqlite c $ do
  -- Remove the Header from the work queue --
  runDelete
    $ delete (headers database)
    (\x -> _header_hash x ==. val_ (_header_hash h))
  -- Write the Miner if unique --
  alreadyMined <- runSelectReturningOne
    $ lookup_ (miners database) (MinerId $ _miner_account m)
  case alreadyMined of
    Just _ -> pure ()
    Nothing -> runInsert . insert (miners database) $ insertValues [m]
  -- Write the Block and TXs if unique --
  alreadyIn <- runSelectReturningOne
    $ lookup_ (blocks database) (BlockId $ _block_hash b)
  case alreadyIn of
    Just _ -> liftIO . T.putStrLn $ "[WARN] Block already in DB: " <> unDbHash (_block_hash b)
    Nothing -> do
      runInsert . insert (blocks database) $ insertValues [b]
      runInsert . insert (transactions database) $ insertValues ts
      liftIO $ printf "[OKAY] Chain %d: %d: %s %s\n"
        (_block_chainId b)
        (_block_height b)
        (unDbHash $ _block_hash b)
        (map (const '.') ts)

lookups :: Env -> Header -> IO (Maybe Quad)
lookups e h = runMaybeT $ do
  pl <- MaybeT $ payload e h
  let !mi = miner pl
      !bl = block h mi
      !ts = map (transaction bl) $ _blockPayload_transactions pl
  pure $ Quad pl bl mi ts

miner :: BlockPayload -> Miner
miner pl = Miner acc prd
  where
    MinerData acc prd _ = _blockPayload_minerData pl

block :: Header -> Miner -> Block
block h m = Block
  { _block_creationTime = _header_creationTime h
  , _block_chainId = _header_chainId h
  , _block_height = _header_height h
  , _block_hash = _header_hash h
  , _block_parent = _header_parent h
  , _block_powHash = _header_powHash h
  , _block_target = _header_target h
  , _block_weight = _header_weight h
  , _block_epochStart = _header_epochStart h
  , _block_nonce = _header_nonce h
  , _block_miner = pk m }

transaction :: Block -> CW.Transaction -> Transaction
transaction b tx = Transaction
  { _tx_chainId = _block_chainId b
  , _tx_block = pk b
  , _tx_creationTime = floor $ _chainwebMeta_creationTime mta
  , _tx_ttl = _chainwebMeta_ttl mta
  , _tx_gasLimit = _chainwebMeta_gasLimit mta
  -- , _tx_gasPrice = _chainwebMeta_gasPrice mta
  , _tx_sender = _chainwebMeta_sender mta
  , _tx_nonce = _pactCommand_nonce cmd
  , _tx_requestKey = hashB64U $ CW._transaction_hash tx
  , _tx_code = _exec_code <$> exc
  , _tx_pactId = _cont_pactId <$> cnt
  , _tx_rollback = _cont_rollback <$> cnt
  , _tx_step = _cont_step <$> cnt
  , _tx_proof = _cont_proof <$> cnt }
  where
    cmd = CW._transaction_cmd tx
    mta = _pactCommand_meta cmd
    pay = _pactCommand_payload cmd
    exc = case pay of
      ExecPayload e -> Just e
      ContPayload _ -> Nothing
    cnt = case pay of
      ExecPayload _ -> Nothing
      ContPayload c -> Just c

--------------------------------------------------------------------------------
-- Endpoints

payload :: Env -> Header -> IO (Maybe BlockPayload)
payload (Env m _ (Url u) (ChainwebVersion v)) h = do
  req <- parseRequest url
  res <- httpLbs req m
  pure . decode' $ responseBody res
  where
    url = "https://" <> u <> T.unpack query
    query = "/chainweb/0.0/" <> v <> "/chain/" <> cid <> "/payload/" <> hsh
    cid = T.pack . show $ _header_chainId h
    hsh = unDbHash $ _header_payloadHash h
