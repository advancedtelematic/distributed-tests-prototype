module Linearisability
  ( History
  , linearisable
  , trace
  , wellformed
  )
  where

import           Control.Distributed.Process
                   (ProcessId)
import           Data.Tree
                   (Forest, Tree(Node))
import           Text.Printf
                   (printf)

------------------------------------------------------------------------

type History   pid inv resp = [(pid, Either inv resp)]

data Operation pid inv resp = Operation pid inv resp
  deriving Show

------------------------------------------------------------------------

takeInvocations :: History pid inv resp -> [(pid, inv)]
takeInvocations []                       = []
takeInvocations ((pid, Left inv) : hist) = (pid, inv) : takeInvocations hist
takeInvocations ((_,   Right _)  : _)    = []

findResponse :: Eq pid => pid -> History pid inv resp -> [(resp, History pid inv resp)]
findResponse _   []                                      = []
findResponse pid ((pid', Right resp) : es) | pid == pid' = [(resp, es)]
findResponse pid (e                  : es)               =
  [ (resp, e : es') | (resp, es') <- findResponse pid es ]

interleavings :: Eq pid => History pid inv resp -> Forest (Operation pid inv resp)
interleavings [] = []
interleavings es =
  [ Node (Operation pid inv resp) (interleavings es')
  | (pid, inv)  <- takeInvocations es
  , (resp, es') <- findResponse pid (filter1 (not . matchInvocation pid) es)
  ]
  where
    matchInvocation pid (pid', Left _) = pid == pid'
    matchInvocation _   _              = False

    filter1 :: (a -> Bool) -> [a] -> [a]
    filter1 _ []                   = []
    filter1 p (x : xs) | p x       = x : filter1 p xs
                       | otherwise = xs

linearisable
  :: Eq pid
  => (model -> Either inv resp -> model)
  -> (model -> inv -> resp -> Bool)
  -> model
  -> History pid inv resp
  -> Bool
linearisable _          _             _      [] = True
linearisable transition postcondition model0 es =
  any (step model0) (interleavings es)
    where
      step model (Node (Operation _ inv resp) roses) =
        postcondition model inv resp &&
        any' (step (transition (transition model (Left inv)) (Right resp))) roses
          where
            any' :: (a -> Bool) -> [a] -> Bool
            any' _ [] = True
            any' p xs = any p xs

------------------------------------------------------------------------

prettyPrintProcessId :: ProcessId -> String
prettyPrintProcessId = reverse . takeWhile (/= ':') . reverse . show

trace
  :: (Show model, Show inv, Show resp)
  => (model -> Either inv resp -> model) -> model -> History ProcessId inv resp -> String
trace transitions = go
  where
    go _     []                         = ""
    go model ((pid, Left  inv)  : hist) =
      printf "%s\n  ==> %s  [%s]\n%s"
        (show model)
        (show inv)
        (prettyPrintProcessId pid)
        (go (transitions model (Left inv)) hist)
    go model ((pid, Right resp) : hist) =
      printf "%s\n  <== %s  [%s]\n%s"
        (show model)
        (show resp)
        (prettyPrintProcessId pid)
        (go (transitions model (Right resp)) hist)

------------------------------------------------------------------------

data NotSequential pid inv resp
  = FirstEventIsntInvocation pid resp
  | InvocationFollowedByInvocation pid inv pid inv
  | InvocationFollowedByNonMatchingResponse pid inv pid resp
  | ResponseFollowedByResponse pid resp pid resp
  | ResponseFollowedByInvocation pid resp pid inv
  | LoneResponse pid resp
  deriving Show

processSubhistory :: Eq pid => pid -> History pid inv resp -> History pid inv resp
processSubhistory pid = filter ((== pid) . fst)

isSequential :: Eq pid => History pid inv resp -> Either (NotSequential pid inv resp) ()
isSequential history = case history of
  (pid, Right resp) : _ -> Left (FirstEventIsntInvocation pid resp)
  _                     -> go history
  where
    go []
      = Right ()
    go [(pid, Right resp)]
      = Left (LoneResponse pid resp)
    go [(_, Left _)]
      = Right ()
    go ((pid, Left inv) : (pid', Right resp) : hist)
      | pid == pid' = go hist
      | otherwise   = Left (InvocationFollowedByNonMatchingResponse pid inv pid' resp)
    go ((pid, Left inv) : (pid', Left inv') : _)
      = Left (InvocationFollowedByInvocation pid inv pid' inv')
    go ((pid, Right resp) : (pid', Right resp') : _)
      = Left (ResponseFollowedByResponse pid resp pid' resp')
    go ((pid, Right resp) : (pid', Left inv) : _)
      = Left (ResponseFollowedByInvocation pid resp pid' inv)

wellformed :: Eq pid => [pid] -> History pid inv resp -> Either (NotSequential pid inv resp) ()
wellformed pids history = allRight
  [ isSequential (processSubhistory pid history) | pid <- pids ]
  where
    allRight :: [Either a b] -> Either a ()
    allRight = foldr (>>) (Right ())
