{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ExplicitForAll      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Scheduler
  ( SchedulerSupervisor(..)
  , SchedulerCount(..)
  , SchedulerSequential(..)
  , SchedulerHistory(..)
  , SchedulerEnv(..)
  , schedulerP
  , makeSchedulerState
  )
  where

import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (Process, ProcessId, expect, getSelfPid, send,
                   spawnLocal)
import           Control.Monad
                   (forever)
import           Control.Monad.IO.Class
                   (liftIO)
import           Control.Monad.Reader
                   (ask)
import           Control.Monad.State
                   (get, modify, gets, put)
import           Data.Binary
                   (Binary)
import           Data.Map
                   (Map)
import qualified Data.Map                    as M
import           Data.Maybe
                   (catMaybes)
import           Data.Sequence
                   (Seq)
import qualified Data.Sequence               as Seq
import           Data.Typeable
                   (Typeable)
import           GHC.Generics
                   (Generic)
import           System.Random
                   (StdGen, mkStdGen, randomR)

import           Linearisability
                   (History)
import           StateMachine

------------------------------------------------------------------------

newtype SchedulerSupervisor = SchedulerSupervisor ProcessId
  deriving Generic

instance Binary SchedulerSupervisor

newtype SchedulerCount = SchedulerCount Int
  deriving Generic

instance Binary SchedulerCount

newtype SchedulerSequential = SchedulerSequential [(ProcessId, ProcessId)]
  deriving Generic

instance Binary SchedulerSequential

newtype SchedulerHistory pid inv resp = SchedulerHistory (History pid inv resp)
  deriving Generic

instance (Binary pid, Binary inv, Binary resp) => Binary (SchedulerHistory pid inv resp)

------------------------------------------------------------------------

data SchedulerEnv input output model = SchedulerEnv
  { transition :: model -> Either input output -> model
  , invariant  :: model -> Bool
  }

data Mailbox input output
  = Incoming (Seq input)  (Seq output)
  | Outgoing (Seq output) (Seq input)
  deriving Show

data SchedulerState input output model = SchedulerState
  { mailboxes      :: Map (ProcessId, ProcessId) (Mailbox input output)
  , stdGen         :: StdGen
  , schedulerModel :: model
  , messageCount   :: Int
  , sequential     :: [(ProcessId, ProcessId)]
  }

makeSchedulerState :: Int -> model -> SchedulerState input output model
makeSchedulerState seed model = SchedulerState
  { mailboxes      = M.empty
  , stdGen         = mkStdGen seed
  , schedulerModel = model
  , messageCount   = 0
  , sequential     = []
  }

------------------------------------------------------------------------

pickProcessPair :: Scheduler input output model (Maybe (ProcessId, ProcessId))
pickProcessPair = do
  SchedulerState {..} <- get
  case sequential of
    processPair : _ -> return (Just processPair)
    []              -> case M.keys mailboxes of
      []           -> return Nothing
      processPairs -> do
        let (i, stdGen') = randomR (0, length processPairs - 1) stdGen
            processPair  = processPairs !! i
        put SchedulerState { stdGen = stdGen', .. }
        return (Just processPair)

type Scheduler input output model a =
  StateMachine
    (SchedulerEnv input output model)
    (SchedulerState input output model)
    input output
    a

schedulerSM
  :: SchedulerMessage input output
  -> Scheduler input output model (Maybe (ProcessId, Either input output))
schedulerSM SchedulerTick = do
  count <- gets messageCount
  if count == 0
  then halt
  else do
    mprocessPair <- pickProcessPair
    case mprocessPair of
      Nothing          -> return Nothing
      Just processPair -> do
        mboxes <- gets mailboxes
        case mboxes M.! processPair of
          Incoming reqs resps -> case Seq.viewl reqs of
            Seq.EmptyL        -> return Nothing
            req Seq.:< reqs' -> do
              SchedulerEnv {..} <- ask
              -- unless (invariant model) $ do
              --   tell (printf "scheduler: invariant broken by `%s'" (show msg))
              --   halt
              modify $ \s -> s
                { mailboxes      = M.insert processPair (Outgoing resps reqs') (mailboxes s)
                , schedulerModel = transition (schedulerModel s) (Left req)
                , messageCount   = messageCount s - 1
                , sequential     = drop 1 (sequential s)
                }
              let (from, to) = processPair
              to ? req
              return (Just (from, Left req))
          Outgoing resps reqs -> case Seq.viewl resps of
            Seq.EmptyL         -> return Nothing
            resp Seq.:< resps' -> do
              SchedulerEnv {..} <- ask
              -- unless (invariant model) $ do
              --   tell (printf "scheduler: invariant broken by `%s'" (show msg))
              --   halt
              modify $ \s -> s
                { mailboxes      = M.insert processPair (Incoming reqs resps') (mailboxes s)
                , schedulerModel = transition (schedulerModel s) (Right resp)
                , messageCount   = messageCount s - 1
                , sequential     = drop 1 (sequential s)
                }
              let (to, _from) = processPair
              to ! resp
              return (Just (to, Right resp))
schedulerSM (SchedulerRequest from req to) = do
  modify $ \s -> s { mailboxes = M.alter f (from, to) (mailboxes s) }
  return Nothing
    where
      f Nothing     = Just (Incoming (Seq.singleton req) Seq.empty)
      f (Just mbox) = case mbox of
                        Incoming reqs resps -> Just (Incoming (reqs Seq.|> req) resps)
                        Outgoing resps reqs -> Just (Outgoing resps (reqs Seq.|> req))
schedulerSM (SchedulerResponse from resp to) = do
  modify $ \s -> s { mailboxes = M.alter f (to, from) (mailboxes s) }
  return Nothing
    where
      f Nothing     = Just (Outgoing (Seq.singleton resp) Seq.empty)
      f (Just mbox) = case mbox of
                        Incoming reqs resps -> Just (Incoming reqs (resps Seq.|> resp))
                        Outgoing resps reqs -> Just (Outgoing (resps Seq.|> resp) reqs)

schedulerP
  :: forall input output model
  .  (Binary input, Typeable input)
  => (Binary output, Typeable output)
  => SchedulerEnv input output model
  -> SchedulerState input output model
  -> Process ()
schedulerP env st = do
  self <- getSelfPid
  SchedulerSupervisor supervisor <- expect
  SchedulerCount count <- expect
  SchedulerSequential processPairs <- expect
  let st' = st { messageCount = count, sequential = processPairs }
  _ <- spawnLocal $ forever $ do
    liftIO (threadDelay 200)
    send self (SchedulerTick :: SchedulerMessage input output)
  hist <- catMaybes <$> stateMachineProcess env st' False schedulerSM
  send supervisor (SchedulerHistory hist)
