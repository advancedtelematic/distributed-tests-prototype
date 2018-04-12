{-# LANGUAGE ExplicitForAll      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Scheduler where

import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (Process, ProcessId, getSelfPid, register, send,
                   spawnLocal)
import           Control.Monad
                   (forever, unless)
import           Control.Monad.IO.Class
                   (liftIO)
import           Control.Monad.Reader
                   (ask)
import           Control.Monad.State
                   (get, modify, put)
import           Data.Binary
                   (Binary)
import           Data.Map
                   (Map)
import qualified Data.Map                    as M
import           Data.Typeable
                   (Typeable)
import           System.Random
                   (StdGen, mkStdGen, randomR)
import           Test.QuickCheck
                   (Arbitrary, Gen, arbitrary, suchThat)
import           Text.Printf
                   (printf)

import           Lib
import           StateMachine

------------------------------------------------------------------------

generator
  :: (model -> Gen msg)
  -> (model -> msg -> Bool)
  -> (model -> msg -> model)
  -> model
  -> Gen [msg]
generator gen precondition transition = go
  where
  go model = do
    msg <- gen model `suchThat` precondition model
    (:) <$> pure msg <*> go (transition model msg)

data SchedulerEnv msg model = SchedulerEnv
  { transition    :: model -> msg -> model
  , postcondition :: model -> msg -> Bool
  }

data SchedulerState msg model = SchedulerState
  { mailboxes :: Map (ProcessId, ProcessId) (Queue msg)
  , stdGen    :: StdGen
  , model     :: model
  }
  deriving Show

makeSchedulerState :: Int -> model -> SchedulerState msg model
makeSchedulerState seed model = SchedulerState
  { mailboxes = M.empty
  , stdGen    = mkStdGen seed
  , model     = model
  }

------------------------------------------------------------------------

schedulerSM
  :: Show msg
  => Show model
  => SchedulerMessage msg
  -> StateMachine (SchedulerEnv msg model) (SchedulerState msg model) msg
schedulerSM Tick = do
  s@SchedulerState {..} <- get
  let processPairs = M.keys mailboxes
  if null processPairs
  then halt
  else do
    let (i, stdGen') = randomR (0, length processPairs - 1) stdGen
        processPair  = processPairs !! i
    case dequeue (mailboxes M.! processPair) of
      (Nothing, _)       -> do
        tell "scheduler: impossible, empty mailbox."
        halt
      (Just msg, queue') -> do
        SchedulerEnv {..} <- ask
        unless (postcondition model msg) $ do
          tell (printf "scheduler: postcondition failed for: %s\nstate: %s" (show msg) (show s))
          halt
        let f _  | isEmpty queue' = Nothing
                 | otherwise      = Just queue'
        put SchedulerState
              { mailboxes = M.update f processPair mailboxes
              , stdGen    = stdGen'
              , model     = transition model msg
              }
        snd processPair ! msg
schedulerSM Send {..} = do
  SchedulerState {..} <- get
  put SchedulerState { mailboxes = M.alter f (from, to) mailboxes, .. }
    where
      f Nothing      = Just (mkQueue [message] [])
      f (Just queue) = Just (enqueue queue message)

schedulerP
  :: forall model msg. (Show model, Show msg, Binary msg, Typeable msg)
  => SchedulerEnv msg model -> Int -> model -> Process ()
schedulerP env seed model = do
  self <- getSelfPid
  register "scheduler" self
  spawnLocal $ forever $ do
    liftIO (threadDelay 1000000)
    send self (Tick :: SchedulerMessage msg)
  stateMachineProcess env (makeSchedulerState seed model) Nothing schedulerSM
