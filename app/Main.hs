{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent
                   (threadDelay)
import           Control.Distributed.Process
                   (Process, ProcessId, NodeId(..), whereis, say, spawnLocal)
import           Control.Distributed.Process.Node
                   (initRemoteTable, newLocalNode, runProcess)
import           Control.Exception
                   (IOException, catch)
import           Data.Maybe
                   (fromMaybe)
import           Data.String
                   (fromString)
import           Network
                   (PortID(PortNumber), PortNumber, connectTo)
import           Network.Transport
                   (EndPointAddress(..))
import           Network.Transport.TCP
                   (createTransport, defaultTCPParameters)
import           System.Environment
                   (getArgs, getProgName, lookupEnv)
import           System.Exit
                   (exitFailure, exitSuccess)
import           System.IO
                   (Handle, hClose)

import           Lib
import           Scheduler

------------------------------------------------------------------------

main :: IO ()
main = do
  prog <- getProgName
  args <- getArgs

  masterHost <- fromMaybe "127.0.0.1" <$> lookupEnv "MASTER_SERVICE_HOST"
  masterPort <- fromMaybe "8080"      <$> lookupEnv "MASTER_SERVICE_PORT"

  let masterNodeId =
        NodeId (EndPointAddress (fromString (masterHost ++ ":" ++ masterPort ++ ":0")))

  case args of
    "master" : host : args' -> do
      transport <- makeTransport host masterHost masterPort
      nid <- newLocalNode transport initRemoteTable
      runProcess nid (masterP args' Nothing)
      threadDelay (3 * 1000000)
      exitSuccess
    ["slave", host, port] -> do
      transport <- makeTransport host host port
      nid <- newLocalNode transport initRemoteTable
      waitForHost masterHost (read masterPort)
      runProcess nid (workerP (Left masterNodeId) Nothing)
      threadDelay (3 * 1000000)
      exitSuccess
    ["test"] -> do
      transport <- makeTransport "127.0.0.1" "127.0.0.1" "50100"
      nid <- newLocalNode transport initRemoteTable
      runProcess nid $ do
        spawnLocal (schedulerP (SchedulerEnv next post) 0 (Model 3))
        pid <- lookupPid "scheduler"
        say (show pid)
        spawnLocal (masterP ["bla", "bli", "blu"] (Just pid))
        masterPid <- lookupPid "master"
        spawnLocal (workerP (Right masterPid) (Just pid))
        workerP (Right masterPid) (Just pid)
      threadDelay (3 * 1000000)
      exitSuccess
    _ -> do
      putStrLn $ "usage: " ++ prog ++ " (master host | slave host port | test)"
      exitFailure
  where
  lookupPid :: String -> Process ProcessId
  lookupPid name = do
    mpid <- whereis name
    case mpid of
      Nothing  -> lookupPid name
      Just pid -> return pid

  makeTransport host externalHost port = do
    etransport <- createTransport host port (\port' -> (externalHost, port')) defaultTCPParameters
    case etransport of
      Left  err       -> do
        putStrLn (show err)
        exitFailure
      Right transport -> return transport

  waitForHost :: String -> PortNumber -> IO ()
  waitForHost host port = do
    putStrLn ("waitForHost: " ++ host ++ ":" ++ show port)
    hClose =<< go 10
    where
      go :: Int -> IO Handle
      go 0 = error "waitForHost"
      go n = connectTo host (PortNumber port)
               `catch` (\(_ :: IOException) -> do
                           threadDelay 1000000
                           go (n - 1))
