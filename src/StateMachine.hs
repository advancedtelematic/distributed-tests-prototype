{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE ExplicitForAll        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module StateMachine
  ( StateMachine
  , runStateMachine
  , stateMachineProcess
  , halt
  , StateMachine.tell
  , (!)
  )
  where

import           Control.Distributed.Process
                   (Process, ProcessId, match, receiveWait, say, send)
import           Control.Monad
                   (forM_)
import           Control.Monad.Except
                   (ExceptT, MonadError, runExceptT, throwError)
import           Control.Monad.IO.Class
                   (MonadIO, liftIO)
import           Control.Monad.Reader
                   (MonadReader, ReaderT, runReaderT)
import           Control.Monad.State
                   (MonadState, StateT, execStateT)
import           Control.Monad.Writer        as Writer
                   (MonadWriter, WriterT, runWriterT, tell)
import           Data.Binary
                   (Binary)
import           Data.Typeable
                   (Typeable)

------------------------------------------------------------------------

type MonadStateMachine config state output m =
  ( MonadReader config m
  , MonadWriter [Either String (ProcessId, output)] m
  , MonadState state m
  , MonadError HaltStateMachine m
  , MonadIO m
  )

data HaltStateMachine = HaltStateMachine

type StateMachine config state output =
  ReaderT config
    (StateT state
       (ExceptT HaltStateMachine
          (WriterT [Either String (ProcessId, output)] IO)))

------------------------------------------------------------------------

runStateMachine
  :: config -> state -> StateMachine config state output a
  -> IO (Either HaltStateMachine state, [Either String (ProcessId, output)])
runStateMachine cfg st
  = runWriterT
  . runExceptT
  . flip execStateT st
  . flip runReaderT cfg

stateMachineProcess
  :: (Binary input,  Typeable input)
  => (Binary output, Typeable output)
  => config -> state -> (input -> StateMachine config state output a) -> Process ()
stateMachineProcess cfg st k = do
  (mst', outputs) <- receiveWait [ match (liftIO . runStateMachine cfg st . k) ]
  forM_ outputs $ \output -> case output of
    Left str         -> say str
    Right (pid, msg) -> send pid msg
  case mst' of
    Left HaltStateMachine -> return ()
    Right st'             -> stateMachineProcess cfg st' k

------------------------------------------------------------------------

halt :: MonadStateMachine config output state m => m a
halt = throwError HaltStateMachine

(!) :: MonadStateMachine config state output m => ProcessId -> output -> m ()
pid ! msg = Writer.tell [Right (pid, msg)]

tell :: MonadStateMachine config state output m => String -> m ()
tell = Writer.tell . (:[]) . Left
