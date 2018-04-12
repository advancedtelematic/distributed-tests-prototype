{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}

module Lib where

import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (NodeId(..), Process, ProcessId, WhereIsReply(..),
                   expectTimeout, getSelfPid, liftIO, match, matchAny,
                   receiveTimeout, register, say, send,
                   whereisRemoteAsync)
import           Control.Monad
                   (when)
import           Control.Monad.Reader
                   (ask)
import           Control.Monad.State
                   (gets, modify)
import           Data.Binary
                   (Binary)
import           Data.Foldable
                   (foldl')
import           Data.Monoid
                   ((<>))
import           Data.Typeable
                   (Typeable)
import           GHC.Generics
                   (Generic)
import           Test.Hspec.Core.Runner
                   (Summary(..))
import           Text.Printf
                   (printf)

import           StateMachine

import           Test

------------------------------------------------------------------------

newtype Enqueue a = Enqueue [a] deriving Show
newtype Dequeue a = Dequeue [a] deriving Show

data Queue a = Queue (Enqueue a) (Dequeue a) deriving Show

instance Monoid (Queue a) where
  mempty = mkQueue [] []
  mappend (Queue (Enqueue es) (Dequeue ds))
          (Queue (Enqueue fs) (Dequeue gs))
    = mkQueue (fs ++ reverse gs ++ es) (ds)

mkQueue :: [a] -> [a] -> Queue a
mkQueue es [] = Queue (Enqueue []) (Dequeue $ reverse es)
mkQueue es ds = Queue (Enqueue es) (Dequeue ds)

enqueue :: Queue a -> a -> Queue a
enqueue (Queue (Enqueue es) (Dequeue ds)) e = mkQueue (e:es) ds

dequeue :: Queue a -> (Maybe a, Queue a)
dequeue (Queue (Enqueue []) (Dequeue [])) = (Nothing, mempty)
dequeue (Queue (Enqueue es) (Dequeue (d:ds))) = (Just d, mkQueue es ds)
dequeue _ = error "unexpected invariant: front of queue is empty but rear is not"

isEmpty :: Queue a -> Bool
isEmpty (Queue (Enqueue []) (Dequeue [])) = True
isEmpty _                                 = False

------------------------------------------------------------------------

data Task = Task String
  deriving (Typeable, Generic, Show, Ord, Eq)

instance Binary Task

data Message
  = AskForTask ProcessId
  | DeliverTask Task
  | WorkDone
  | TaskFinished ProcessId Task TaskResult
  deriving (Typeable, Generic, Show)

data TaskResult = TaskResult Int Int
  deriving (Generic, Show)

instance Binary TaskResult

summaryFromTaskResult :: TaskResult -> Summary
summaryFromTaskResult (TaskResult exs fails) = Summary exs fails

instance Binary Message

------------------------------------------------------------------------

workerP :: Either NodeId ProcessId -> Maybe ProcessId -> Process ()
workerP master mscheduler = do
  self <- getSelfPid
  say $ printf "slave alive on %s" (show self)
  pid <- case master of
    Left  nid -> waitForNode nid "master"
    Right pid -> return pid
  case mscheduler of
    Nothing        -> send pid (AskForTask self)
    Just scheduler -> send scheduler (Send self (AskForTask self) pid)
  stateMachineProcess (self, pid) () mscheduler workerSM

waitForNode :: NodeId -> String -> Process ProcessId
waitForNode nid name = do
  say (printf "waiting for %s to appear on %s" name (show nid))
  whereisRemoteAsync nid name
  reply <- expectTimeout 1000
  case reply of
    Just (WhereIsReply _ (Just pid)) -> do
      say (printf "found %s!" name)
      return pid
    _                                -> do
      liftIO (threadDelay 10000)
      waitForNode nid name

workerSM :: Message -> StateMachine (ProcessId, ProcessId) () Message
workerSM (DeliverTask task@(Task descr)) = do
  tell $ printf "running: %s" (show task)
  Summary exs fails <- liftIO $ runTests descr
  tell $ printf "done: %s" (show task)
  (self, master) <- ask
  master ! TaskFinished self task (TaskResult exs fails)
  master ! AskForTask self
workerSM WorkDone = halt
workerSM _ = error "invalid state transition"

------------------------------------------------------------------------

masterP :: [String] -> Maybe ProcessId -> Process ()
masterP args mscheduler = do
  self <- getSelfPid
  say $ printf "master alive on %s: %s" (show self) (unwords args)
  register "master" self
  let n = length args
      q = foldl' (\akk -> (enqueue akk) . Task) mempty args
  stateMachineProcess () (MasterState n q mempty) mscheduler masterSM

data MasterState = MasterState
  { step    :: Int
  , queue   :: Queue Task
  , summary :: Summary
  }

masterSM :: Message -> StateMachine () MasterState Message
masterSM (AskForTask pid) = do
  q <- gets queue
  case dequeue q of
    (Just task, q') -> do
      modify (\s -> s { queue = q' })
      pid ! DeliverTask task
    (Nothing, _)    -> do
      pid ! WorkDone
      n <- gets step
      when (n == 0) halt
masterSM (TaskFinished pid task result) = do
  tell $ printf "%s: %s done with %s" (show task) (show result) (show pid)
  n <- gets step
  summary' <- gets summary
  let summary'' = summary' <> summaryFromTaskResult result
  if n == 0
  then do
    tell $ printf "summary: " <> show summary''
    halt
  else do
    modify (\s -> s { step = pred $ step s
                    , summary = summary''
                    })
masterSM _ = error "invalid state transition"

------------------------------------------------------------------------

newtype Model = Model Int
  deriving (Eq, Show, Num)

next :: Model -> Message -> Model
next m (AskForTask _)       = m
next m (DeliverTask _)      = m
next m (TaskFinished _ _ _) = m - 1
next m WorkDone             = m

post :: Model -> Message -> Bool
post m WorkDone = m == 0
post _ _        = True
