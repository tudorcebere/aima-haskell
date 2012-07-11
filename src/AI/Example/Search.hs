{-# LANGUAGE FlexibleInstances #-}

module AI.Example.Search where

import Control.DeepSeq
import Control.Monad.State (StateT)
import Control.Monad
import Data.IORef
import Data.Map (Map, (!))
import Data.Maybe (fromJust)
import System.IO.Unsafe

import qualified Control.Monad.State as ST
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Ord as O
import qualified System.Random as R

import AI.Search
import AI.Util.WeightedGraph (WeightedGraph)
import AI.Util.Table
import AI.Util.Util

import qualified AI.Util.WeightedGraph as G

-------------------------------
-- Graphs and Graph Problems --
-------------------------------

-- |Data structure to hold a graph (edge weights correspond to the distance
--  between nodes) and a map of graph nodes to locations.
data GraphMap a = G
    { getGraph     :: WeightedGraph a Cost
    , getLocations :: Map a Location } deriving (Show)

-- |Type synonym for a pair of doubles, representing a location in cartesian
--  coordinates.
type Location = (Double,Double)

-- |Creates a GraphMap from the graph's adjacency list representation and a list
--  of (node, location) pairs. This function creates undirected graphs, so you
--  don't need to include reverse links in the adjacency list (though you can
--  if you like).
mkGraphMap :: (Ord a) => [(a,[(a,Cost)])] -> [(a,Location)] -> GraphMap a
mkGraphMap conn loc = G (G.toUndirectedGraph conn) (M.fromList loc)

-- |Get the neighbours of a node from a GraphMap.
getNeighbours :: Ord a => a -> GraphMap a -> [(a,Cost)]
getNeighbours a (G g _) = G.getNeighbours a g

-- |Get the location of a node from a GraphMap.
getLocation :: Ord a => a -> GraphMap a -> Location
getLocation a (G _ l) = case M.lookup a l of
    Nothing -> error "Vertex not found in graph -- GETLOCATION"
    Just pt -> pt

-- | Add an edge between two nodes to a GraphMap.
addEdge :: Ord a => a -> a -> Cost -> GraphMap a -> GraphMap a
addEdge x y cost (G graph locs) = G (G.addUndirectedEdge x y cost graph) locs

-- |The cost associated with moving between two nodes in a GraphMap. If the
--  nodes are not connected by an edge, then the cost is returned as infinity.
costFromTo :: Ord a => GraphMap a -> a -> a -> Cost
costFromTo graph a b = case lookup b (getNeighbours a graph) of
    Nothing -> 1/0
    Just c  -> c

-- |Data structure to hold a graph problem (represented as a GraphMap together
--  with an initial and final node).
data GraphProblem s a = GP
    { graphGP :: GraphMap s
    , initGP :: s
    , goalGP :: s } deriving (Show)

-- |GraphProblems are an instance of Problem. The heuristic function measures
--  the Euclidean (straight-line) distance between two nodes. It is assumed that
--  this is less than or equal to the cost of moving along edges.
instance Ord s => Problem GraphProblem s s where
    initial = initGP
    goal = goalGP
    successor (GP g _ _) s = [ (x,x) | (x,_) <- getNeighbours s g ]
    costP (GP g _ _) c s _ s' = c + costFromTo g s s'
    heuristic (GP g _ goal) n = euclideanDist x y
        where
            x = getLocation (state n) g
            y = getLocation goal g

-- |Measures the Euclidean (straight-line) distance between two locations.
euclideanDist :: Location -> Location -> Double
euclideanDist (x,y) (x',y') = sqrt $ (x-x')^2 + (y-y')^2

-- |The Romania graph from AIMA.
romania :: GraphMap String
romania = mkGraphMap

    [ ("A", [("Z",75), ("S",140), ("T",118)])
    , ("B", [("U",85), ("P",101), ("G",90), ("F",211)])
    , ("C", [("D",120), ("R",146), ("P",138)])
    , ("D", [("M",75)])
    , ("E", [("H",86)])
    , ("F", [("S",99)])
    , ("H", [("U",98)])
    , ("I", [("V",92), ("N",87)])
    , ("L", [("T",111), ("M",70)])
    , ("O", [("Z",71), ("S",151)])
    , ("P", [("R",97)])
    , ("R", [("S",80)])
    , ("U", [("V",142)]) ]

    [ ("A",( 91,491)), ("B",(400,327)), ("C",(253,288)), ("D",(165,299))
    , ("E",(562,293)), ("F",(305,449)), ("G",(375,270)), ("H",(534,350))
    , ("I",(473,506)), ("L",(165,379)), ("M",(168,339)), ("N",(406,537))
    , ("O",(131,571)), ("P",(320,368)), ("R",(233,410)), ("S",(207,457))
    , ("T",( 94,410)), ("U",(456,350)), ("V",(509,444)), ("Z",(108,531)) ]

-- |The Australia graph from AIMA.
australia :: GraphMap String
australia = mkGraphMap

    [ ("T",   [])
    , ("SA",  [("WA",1), ("NT",1), ("Q",1), ("NSW",1), ("V",1)])
    , ("NT",  [("WA",1), ("Q",1)])
    , ("NSW", [("Q", 1), ("V",1)]) ]

    [ ("WA",(120,24)), ("NT" ,(135,20)), ("SA",(135,30)),
      ("Q" ,(145,20)), ("NSW",(145,32)), ("T" ,(145,42)), ("V",(145,37))]

-- |Three example graph problems from AIMA.
gp1, gp2, gp3  :: GraphProblem String String
gp1 = GP { graphGP = australia, initGP = "Q", goalGP = "WA" }
gp2 = GP { graphGP = romania, initGP = "A", goalGP = "B" }
gp3 = GP { graphGP = romania, initGP = "O", goalGP = "N" }

-- |Construct a random graph with the specified number of nodes, and random
--  links. The nodes are laid out randomly on a @(width x height)@ rectangle.
--  Then each node is connected to the @minLinks@ nearest neighbours. Because
--  inverse links are added, some nodes will have more connections. The distance
--  between nodes is the hypotenuse multiplied by @curvature@, where @curvature@
--  defaults to a random number between 1.1 and 1.5.
randomGraphMap ::
                 Int    -- ^ Number of nodes
              -> Int    -- ^ Minimum number of links
              -> Double -- ^ Width
              -> Double -- ^ Height
              -> IO (GraphMap Int)
randomGraphMap n minLinks width height = ST.execStateT go (mkGraphMap [] []) where
    go = do
        replicateM n mkLocation >>= ST.put . mkGraphMap [] . zip nodes

        forM_ nodes $ \x -> do

            ST.modify (addEmpty x)
            g @ (G _ loc) <- ST.get

            let nbrs     = map fst (getNeighbours x g)
                numNbrs  = length nbrs

                unconnected = deleteAll (x:nbrs) nodes
                sorted      = L.sortBy (O.comparing to_x) unconnected
                to_x y      = euclideanDist (loc ! x) (loc ! y)
                toAdd       = take (minLinks - numNbrs) sorted
            
            mapM_ (addLink x) toAdd

        where
            nodes = [1..n]

            addLink x y = do
                curv <- curvature
                dist <- distance x y
                ST.modify $ addEdge x y (dist * curv)

            addEmpty x (G graph xs) = G (M.insert x M.empty graph) xs

            mkLocation = ST.liftIO $ do
                x <- R.randomRIO (0,width)
                y <- R.randomRIO (0,height)
                return (x,y)

            curvature = ST.liftIO $ R.randomRIO (1.1, 1.5)

            distance x y = do
                (G _ loc) <- ST.get
                return $ euclideanDist (loc ! x) (loc ! y)

-- |Return a random instance of a graph problem with the specified number of
--  nodes and minimum number of links.
randomGraphProblem :: Int -> Int -> IO (GraphProblem Int Int)
randomGraphProblem numNodes minLinks = do
    g <- randomGraphMap numNodes minLinks 100 100
    return (GP g 1 numNodes)

----------------------
-- N Queens Problem --
----------------------

-- |Data structure to define an N-Queens problem (the problem is defined by
--  the size of the board).
data NQueens s a = NQ { sizeNQ :: Int } deriving (Show)

-- |Update the state of the N-Queens board by playing a queen at (i,n).
updateNQ :: (Int,Int) -> [Maybe Int] -> [Maybe Int]
updateNQ (c,r) s = insert c (Just r) s

-- |Would putting two queens in (r1,c1) and (r2,c2) conflict?
conflict :: Int -> Int -> Int -> Int -> Bool
conflict r1 c1 r2 c2 =
    r1 == r2 || c1 == c2 || r1-c1 == r2-c2 || r1+c1 == r2+c2

-- |Would placing a queen at (row,col) conflict with anything?
conflicted :: [Maybe Int] -> Int -> Int -> Bool
conflicted state row col = or $ map f (enumerate state)
    where
        f (_, Nothing) = False
        f (c, Just r)  = if c == col && r == row
            then False
            else conflict row col r c

-- |N-Queens is an instance of Problem. 
instance Problem NQueens [Maybe Int] (Int,Int) where
    initial (NQ n) = replicate n Nothing

    -- @L.elemIndex Nothing s@ finds the index of the first column in s
    -- that doesn't yet have a queen.
    successor (NQ n) s = case L.elemIndex Nothing s of
        Nothing -> []
        Just i  -> zip actions (map (`updateNQ` s) actions)
            where
                actions = map ((,) i) [0..n-1]

    goalTest (NQ n) s = if last s == Nothing
        then False
        else not . or $ map f (enumerate s)
            where
                f (c,Nothing) = False
                f (c,Just r)  = conflicted s r c

-- |An example N-Queens problem on an 8x8 grid.
nQueens :: NQueens [Maybe Int] (Int,Int)
nQueens = NQ 8

-----------------------
-- Compare Searchers --
-----------------------

-- |Wrapper for a problem that keeps statistics on how many times nodes were
--  expanded in the course of a search. We track the number of times 'goalCheck'
--  was called, the number of times 'successor' was called, and the total number
--  of states expanded.
data ProblemIO p s a = PIO
    { problemIO     :: p s a
    , numGoalChecks :: IORef Int
    , numSuccs      :: IORef Int
    , numStates     :: IORef Int }

-- |Construct a new ProblemIO, with all counters initialized to zero.
mkProblemIO :: p s a -> IO (ProblemIO p s a)
mkProblemIO p = do
    i <- newIORef 0
    j <- newIORef 0
    k <- newIORef 0
    return (PIO p i j k)

-- |Make ProblemIO into an instance of Problem. It uses the same implementation
--  as the problem it wraps, except that whenever 'goalTest' or 's'
instance (Problem p s a, Eq s, Show s) => Problem (ProblemIO p) s a where
    initial (PIO p _ _ _) = initial p

    goalTest (PIO p n _ _) s = unsafePerformIO $ do
        modifyIORef n (+1)
        return (goalTest p s)

    successor (PIO p _ n m) s = unsafePerformIO $ do
        let succs = successor p s
        modifyIORef n (+1)
        modifyIORef m (+length succs)
        return succs

    costP (PIO p _ _ _) = costP p

    heuristic (PIO p _ _ _) = heuristic p

-- |Given a problem and a search algorithm, run the searcher on the problem
--  and return the solution found, together with statistics about how many
--  nodes were expanded in the course of finding the solution.
testSearcher :: p s a -> (ProblemIO p s a -> t) -> IO (t,Int,Int,Int)
testSearcher prob searcher = do
    p@(PIO _ numGoalChecks numSuccs numStates) <- mkProblemIO prob
    let result = searcher p in result `seq` do
        i <- readIORef numGoalChecks
        j <- readIORef numSuccs
        k <- readIORef numStates
        return (result, i, j, k)

-- |NFData instance for search nodes.
instance (NFData s, NFData a) => NFData (Node s a) where
    rnf (Node state parent action cost depth value) = 
        state `seq` parent `seq` action `seq`
        cost `seq`depth `seq` value `seq`
        Node state parent action cost depth value `seq` ()

-- |Run a search algorithm over a problem, returning the time it took as well
--  as other statistics.
testSearcher' :: (NFData t) => p s a -> (ProblemIO p s a -> t) -> IO (t,Int,Int,Int,Int)
testSearcher' prob searcher = do
    p@(PIO _ numGoalChecks numSuccs numStates) <- mkProblemIO prob
    (result, t) <- timed (searcher p)
    i <- readIORef numGoalChecks
    j <- readIORef numSuccs
    k <- readIORef numStates
    return (result, t, i, j, k)

-- |Test multiple searchers on the same problem, and return a list of results
--  and statistics.
testSearchers :: [ProblemIO p s a -> t] -> p s a -> IO [(t,Int,Int,Int)]
testSearchers searchers prob = testSearcher prob `mapM` searchers

-- |Given a list of problems and a list of searchers, run 'testSearcher'
--  pairwise and print out a table showing the performance of each algorithm.
compareSearchers :: (Show t) =>
                    [ProblemIO p s a -> t]  -- ^ List of search algorithms
                 -> [p s a]                 -- ^ List of problems
                 -> [String]                -- ^ Problem names
                 -> [String]                -- ^ Search algorithm names
                 -> IO [[(t,Int,Int,Int)]]  
compareSearchers searchers probs header rownames = do
    results <- testSearchers searchers `mapM` probs
    printTable 20 (map (map f) (transpose results)) header rownames
    return results
    where
        f (x,i,j,k) = SB (i,j,k)

-- |Given a problem and a list of searchers, run each search algorithm over the
--  problem, and print out a table showing the performance of each searcher.
--  The columns of the table indicate: [Algorithm name, Depth of solution, 
--  Cost of solution, Number of goal checks, Number of node expansions,
--  Number of states expanded] .
detailedCompareSearchers ::
        [ProblemIO p s a -> Maybe (Node s1 a1)] -- ^ List of searchers
     -> [String]                                -- ^ Names of searchers
     -> p s a                                   -- ^ Problem
     -> IO ()
detailedCompareSearchers searchers names prob = do
    result <- testSearchers searchers prob
    table  <- forM result $ \(n,numGoalChecks,numSuccs,numStates) -> do
        let d = depth $ fromJust n
        let c = round $ cost $ fromJust n
        let b = fromIntegral numStates ** (1/fromIntegral d)
        return [SB d,SB c,SB numGoalChecks,SB numSuccs,SB numStates,SB b]
    printTable 20 table header names
    where
        header = ["Searcher","Depth","Cost","Goal Checks","Successors",
                  "States","Eff Branching Factor"]

-- |Run all search algorithms over a few example problems.
compareGraphSearchers :: IO ()
compareGraphSearchers = do
    compareSearchers searchers probs header algonames
    return ()
    where
        searchers = allSearchers
        probs     = [gp1, gp2, gp3]
        header    = ["Searcher", "Australia", "Romania(A,B)","Romania(O,N)"]
        algonames = allSearcherNames

-- |Run all search algorithms over a particular problem and print out
--  performance statistics.
runDetailedCompare :: (Problem p s a, Ord s, Show s) => p s a -> IO ()
runDetailedCompare = detailedCompareSearchers allSearchers allSearcherNames

-- |List of all search algorithms in this module.
allSearchers :: (Problem p s a, Ord s) => [p s a -> Maybe (Node s a)]
allSearchers = [ breadthFirstTreeSearch, breadthFirstGraphSearch
               , depthFirstGraphSearch, iterativeDeepeningSearch
               , greedyBestFirstSearch, uniformCostSearch, aStarSearch']

-- |Names for the search algorithms in this module.
allSearcherNames :: [String]
allSearcherNames = [ "Breadth First Tree Search", "Breadth First WeightedGraph Search"
                   , "Depth First WeightedGraph Search", "Iterative Deepening Search"
                   , "Greedy Best First Search", "Uniform Cost Search"
                   , "A* Search"]