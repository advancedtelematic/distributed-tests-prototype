module QuickCheckHelpers
  ( generateRequests
  , shrinkRequests
  , generateParallelRequests
  , shrinkParallelRequests
  , monadicProcess
  )
  where

import           Control.Arrow
                   (second)
import           Control.Distributed.Process
                   (Process)
import           Control.Monad.State
                   (StateT, evalStateT, get, lift, put, runStateT)
import           Data.List
                   (permutations)
import           Test.QuickCheck
                   (Gen, Property, Testable, choose, ioProperty,
                   shrinkList, sized, suchThat)
import           Test.QuickCheck.Monadic
                   (PropertyM, monadic)

import           Utils

------------------------------------------------------------------------

generateRequestsStateT
  :: (model -> Gen req)
  -> (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> StateT model Gen [req]
generateRequestsStateT generator preconditions transitions =
  go =<< lift (sized (\k -> choose (0, k)))
  where
  go 0    = return []
  go size = do
    model <- get
    msg <- lift (generator model `suchThat` preconditions model)
    put (transitions model (Left msg))
    (msg :) <$> go (size - 1)

generateRequests
  :: (model -> Gen req)
  -> (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> Gen [req]
generateRequests generator preconditions transitions =
  evalStateT (generateRequestsStateT generator preconditions transitions)

generateParallelRequests
  :: (model -> Gen req)
  -> (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> Gen ([req], [req])
generateParallelRequests generator preconditions transitions model = do
  (prefix, model') <- runStateT (generateRequestsStateT generator preconditions transitions) model
  suffix <- generateParallelSafeRequests generator preconditions transitions model'
  return (prefix, suffix)

generateParallelSafeRequests
  :: (model -> Gen req)
  -> (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> Gen [req]
generateParallelSafeRequests generator preconditions transitions = go []
  where
    go reqs model = do
      req <- generator model `suchThat` preconditions model
      let reqs'  = req : reqs
      if length reqs' <= 6 && parallelSafe preconditions transitions model reqs'
      then go reqs' model
      else return (reverse reqs)

parallelSafe
  :: (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> [req]
  -> Bool
parallelSafe preconditions transitions model0
  = all (preconditionsHold model0)
  . permutations
  where
    preconditionsHold _     []           = True
    preconditionsHold model (req : reqs) = preconditions model req &&
      preconditionsHold (transitions model (Left req)) reqs

shrinkRequests
  :: (model -> req -> [req])
  -> (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> [req] -> [[req]]
shrinkRequests shrinker preconditions transitions model0
  = filter (validRequests preconditions transitions model0)
  . shrinkList (shrinker model0)

validRequests :: (model -> req -> Bool) -> (model -> Either req resp -> model) -> model -> [req] -> Bool
validRequests preconditions transitions = go
  where
    go _     []           = True
    go model (req : reqs) = preconditions model req &&
                              go (transitions model (Left req)) reqs

validParallelRequests
  :: (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> ([req], [req])
  -> Bool
validParallelRequests preconditions transitions model (prefix, suffix)
  =  validRequests  preconditions transitions model prefix
  && parallelSafe preconditions transitions model' suffix
  where
    model' = foldl transitions model (map Left prefix)

shrinkParallelRequests
  :: (model -> req -> [req])
  -> (model -> req -> Bool)
  -> (model -> Either req resp -> model)
  -> model
  -> ([req], [req]) -> [([req], [req])]
shrinkParallelRequests shrinker preconditions transitions model (prefix, suffix)
  = filter (validParallelRequests preconditions transitions model)
      [ (prefix', suffix')
      | (prefix', suffix') <- shrinkPair (shrinkList (shrinker model)) (prefix, suffix)
      ]
      ++
      moveSuffixToPrefix
  where
    pickOneReturnRest :: [a] -> [(a, [a])]
    pickOneReturnRest []       = []
    pickOneReturnRest (x : xs) = (x, xs) : map (second (x :)) (pickOneReturnRest xs)

    moveSuffixToPrefix =
      [ (prefix ++ [prefix'], suffix')
      | (prefix', suffix') <- pickOneReturnRest suffix
      ]

monadicProcess :: Testable a => PropertyM Process a -> Property
monadicProcess = monadic (ioProperty . runLocalProcess)

-- | Given shrinkers for the components of a pair we can shrink the pair.
shrinkPair' :: (a -> [a]) -> (b -> [b]) -> ((a, b) -> [(a, b)])
shrinkPair' shrinkerA shrinkerB (x, y) =
  [ (x', y) | x' <- shrinkerA x ] ++
  [ (x, y') | y' <- shrinkerB y ]

-- | Same above, but for homogeneous pairs.
shrinkPair :: (a -> [a]) -> ((a, a) -> [(a, a)])
shrinkPair shrinker = shrinkPair' shrinker shrinker
