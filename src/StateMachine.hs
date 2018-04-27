{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE ExplicitForAll        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module StateMachine
  ( MonadStateMachine
  , StateMachine
  , stateMachineProcess
  , stateMachineProcess_
  , halt
  , StateMachine.tell
  , (!)
  , (?)
  , SchedulerMessage(..) -- XXX
  , SchedulerPid(..) -- XXX
  )
  where

import           Control.Distributed.Process
                   (Process, ProcessId, expect, getSelfPid, match,
                   receiveWait, say, send)
import           Control.Monad
                   (forM_, void)
import           Control.Monad.Except
                   (ExceptT, MonadError, runExceptT, throwError)
import           Control.Monad.IO.Class
                   (MonadIO, liftIO)
import           Control.Monad.Reader
                   (MonadReader, ReaderT, runReaderT)
import           Control.Monad.State
                   (MonadState, StateT, runStateT)
import           Control.Monad.Writer        as Writer
                   (MonadWriter, WriterT, runWriterT, tell)
import           Data.Binary
                   (Binary)
import           Data.Typeable
                   (Typeable)
import           GHC.Generics
                   (Generic)

------------------------------------------------------------------------

data SchedulerMessage input output
  = SchedulerTick
  | SchedulerRequest  ProcessId input  ProcessId
  | SchedulerResponse ProcessId output ProcessId
  deriving (Typeable, Generic, Show)

instance (Binary input, Binary output) => Binary (SchedulerMessage input output)

newtype SchedulerPid = SchedulerPid ProcessId
  deriving Generic

instance Binary SchedulerPid

getSchedulerPid :: Bool -> Process (Maybe ProcessId)
getSchedulerPid False = return Nothing
getSchedulerPid True  = do
  SchedulerPid pid <- expect
  return (Just pid)

------------------------------------------------------------------------

type MonadStateMachine config state output1 output2 m =
  ( MonadReader config m
  , MonadWriter [Either String (ProcessId, Either output1 output2)] m
  , MonadState state m
  , MonadError HaltStateMachine m
  , MonadIO m
  )

data HaltStateMachine = HaltStateMachine

type StateMachine config state output1 output2 =
  ReaderT config
    (StateT state
       (ExceptT HaltStateMachine
          (WriterT [Either String (ProcessId, Either output1 output2)] IO)))

------------------------------------------------------------------------

runStateMachine
  :: config -> state -> StateMachine config state output1 output2 a
  -> IO (Either HaltStateMachine (a, state),
           [Either String (ProcessId, Either output1 output2)])
runStateMachine cfg st
  = runWriterT
  . runExceptT
  . flip runStateT st
  . flip runReaderT cfg

stateMachineProcess_
  :: (Binary input,  Typeable input)
  => (Binary output1, Typeable output1)
  => (Binary output2, Typeable output2)
  => config -> state
  -> Bool
  -> (input -> StateMachine config state output1 output2 ())
  -> Process ()
stateMachineProcess_ cfg st testing = void . stateMachineProcess cfg st testing

stateMachineProcess
  :: forall input output1 output2 config state result
  .  (Binary input,  Typeable input)
  => (Binary output1, Typeable output1)
  => (Binary output2, Typeable output2)
  => config -> state
  -> Bool
  -> (input -> StateMachine config state output1 output2 result)
  -> Process [result]
stateMachineProcess cfg st0 testing k = do
  mscheduler <- getSchedulerPid testing
  go st0 mscheduler
    where
      go st mscheduler = do
        (continue, outputs) <- receiveWait [ match (liftIO . runStateMachine cfg st . k) ]
        forM_ outputs $ \output -> case output of
          Left str         -> say str
          Right (pid, msg) -> case mscheduler of
            Nothing        -> either (send pid) (send pid) msg
            Just scheduler -> do
              self <- getSelfPid
              case msg of
                Left req -> do
                  let sreq :: SchedulerMessage output1 output2
                      sreq = SchedulerRequest self req pid
                  send scheduler sreq
                Right resp -> do
                  let sresp :: SchedulerMessage output1 output2
                      sresp = SchedulerResponse self resp pid
                  send scheduler sresp
        case continue of
          Left HaltStateMachine -> return []
          Right (x, st')        -> (x :) <$> go st' mscheduler

------------------------------------------------------------------------

halt :: MonadStateMachine config state output1 output2 m => m a
halt = throwError HaltStateMachine

(!) :: MonadStateMachine config state output1 output2 m => ProcessId -> output2 -> m ()
pid ! msg = Writer.tell [Right (pid, Right msg)]

(?) :: MonadStateMachine config state output1 output2 m => ProcessId -> output1 -> m ()
pid ? msg = Writer.tell [Right (pid, Left msg)]

tell :: MonadStateMachine config state output1 output2 m => String -> m ()
tell = Writer.tell . (:[]) . Left
