module Utils
  ( withLocalNode
  , runLocalProcess
  )
  where

import           Control.Concurrent.STM
                   (atomically, newEmptyTMVar, putTMVar, takeTMVar)
import           Control.Distributed.Process
                   (Process, liftIO)
import           Control.Distributed.Process.Node
                   (LocalNode(..))
import           Control.Distributed.Process.Node
                   (closeLocalNode, initRemoteTable, newLocalNode,
                   runProcess)
import           Control.Exception
                   (bracket)
import           Network.Transport
                   (closeTransport)
import           Network.Transport.TCP
                   (createTransport, defaultTCPParameters)
import           System.Random
                   (randomRIO)

------------------------------------------------------------------------

withLocalNode :: (LocalNode -> IO a) -> IO a
withLocalNode k = do
  bracket setup cleanup (k . snd)
  where
    setup = do
      transport <- makeTransport
      localNode <- newLocalNode transport initRemoteTable
      return (transport, localNode)

    cleanup (transport, localNode) = do
      closeLocalNode localNode
      closeTransport transport

    makeTransport = do
      port       <- randomRIO (1024, 65535 :: Int)
      etransport <- createTransport "127.0.0.1" (show port) (\port' -> ("127.0.0.1", port')) defaultTCPParameters
      case etransport of
        Left  _         -> makeTransport
        Right transport -> return transport

runLocalProcess :: Process a -> IO a
runLocalProcess process = do
  withLocalNode $ \node -> do
    resultVar <- atomically newEmptyTMVar
    runProcess node $ do
      result <- process
      liftIO (atomically (putTMVar resultVar result))
    atomically (takeTMVar resultVar)
