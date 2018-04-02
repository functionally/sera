{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}


module SERA.Infrastructure.Optimization (
  NetworkGraph
, Vertex(..)
, Edge(..)
, networkGraph
, buildContext
, NetworkContext(..)
, EdgeContext(..)
, TechnologyContext(..)
, TechnologyBuilder
, Optimum(..)
, optimize
) where


import Control.Arrow ((&&&), (***))
import Control.Monad (guard, when)
import Control.Monad.Log (logDebug, logError, logInfo, logNotice)
import Data.Daft.DataCube (evaluable, evaluate, knownKeys)
import Data.Daft.Vinyl.FieldCube ((!), toKnownRecords, σ)
import Data.Daft.Vinyl.FieldRec ((=:), (<:), (<+>))
import Data.Default.Util (inf)
import Data.Graph.Algorithms (minimumCostFlow)
import Data.Graph.Types (Graph(..), makeGraph)
import Data.List (find, nub, unzip4)
import Data.Map (Map)
import Data.Maybe (catMaybes, fromJust, isJust)
import Data.Monoid (Sum(..), (<>))
import Data.Tuple.Util (fst3)
import SERA (SeraLog)
import SERA.Material (Pricer, localize)
import SERA.Network (Network(..))
import SERA.Process.Reification (TechnologyOperation, technologyReifier)
import SERA.Process (ProcessLibrary(..), isProduction)
import SERA.Types.Cubes (DemandCube, IntensityCube, PriceCube)
import SERA.Types.Fields (CostCategory(..), fCapacity, fCapitalCost, fCost, fDutyCycle, fExtended, fFixedCost, fFrom, Infrastructure(..), fInfrastructure, fLifetime, fNameplate, fCostCategory, fFlow, fFuelConsumption, fLength, Location, FLocation, fLocation, fLoss, fMaterial, fNonFuelConsumption, fPrice, fProduction, fSale, fSalvage, Pathway(..), fPathway, Productive(..), fProductive, fStage, Technology(..), fTechnology, fTo, fTransmission, fVariableCost, Year, fYear)
import SERA.Types.Records (Cash, Construction, Flow, Impact)

import qualified Data.Map as M
import qualified Data.Set as S


data Optimum =
  Optimum
  {
    optimalConstruction :: [Construction]
  , optimalFlow         :: [Flow]
  , optimalCash         :: [Cash]
  , optimalImpact       :: [Impact]
  }
    deriving (Eq, Show)

instance Ord Optimum where
  compare x y =
    let
      capacity z = fNameplate <: z * fDutyCycle <: z
    in
      compare (sum . fmap capacity $ optimalConstruction y) (sum . fmap capacity $ optimalConstruction x)

instance Monoid Optimum where
  mempty      = Optimum
                {
                  optimalConstruction = []
                , optimalFlow         = []
                , optimalCash         = []
                , optimalImpact       = []
                }
  mappend x y = Optimum
                {
                  optimalConstruction = optimalConstruction x <> optimalConstruction y
                , optimalFlow         = optimalFlow         x <> optimalFlow         y
                , optimalCash         = optimalCash         x <> optimalCash         y
                , optimalImpact       = optimalImpact       x <> optimalImpact       y
                }

type NetworkGraph = Graph Vertex Edge


data Vertex =
    SuperSource
  | SuperSink
  | ConsumptionVertex Location
  | ProductionVertex Location
  | PathwayVertex Location Pathway Int
    deriving (Eq, Ord, Read, Show)


data Edge =
    DemandEdge Location
  | ExistingEdge Infrastructure
  | CentralEdge Location Technology
  | OnsiteEdge Location Technology
  | PathwayForwardEdge Location Pathway Int
  | PathwayReverseEdge Location Pathway Int
    deriving (Eq, Ord, Read, Show)


networkGraph :: Network -> DemandCube -> ProcessLibrary -> NetworkGraph
networkGraph Network{..} demandCube ProcessLibrary{..} =
  makeGraph
    $ concat
    [
      case compare stage extendedStage of
        LT -> [
                (
                  if stage == firstStage
                    then ProductionVertex location
                    else PathwayVertex location pathway stage
                , PathwayVertex location pathway $ stage + 1
                , PathwayForwardEdge location pathway stage
                )
              |
                node <- toKnownRecords nodeCube
              , let location = fLocation <: node
              ]
        EQ -> concat
              [
                [
                  (from', to'  , PathwayForwardEdge location pathway stage) 
                , (to'  , from', PathwayReverseEdge location pathway stage) 
                ]
              |
                link <- toKnownRecords linkCube
              , let location = fLocation <: link
                    from = fFrom <: link
                    to   = fTo   <: link
                    from' = PathwayVertex from pathway stage
                    to'   = PathwayVertex to   pathway stage
              ]
        GT -> [
                (
                  PathwayVertex location pathway $ stage - 1
                , if stage == lastStage
                    then ConsumptionVertex location  -- FIXME: Only do this when there actually is consumption.
                    else PathwayVertex location pathway stage
                , PathwayForwardEdge location pathway stage
                )
              |
                node <- toKnownRecords nodeCube
              , let location = fLocation <: node
              ]
    |
      pathway <- S.toList $ S.map (fPathway <:) $ knownKeys pathwayCube
    , let stages = toKnownRecords $ σ (\key _ -> pathway == fPathway <: key) pathwayCube
          extendedStage' = find (\rec -> fExtended <: rec && fTransmission <: rec) stages
          firstStage = fStage <: minimum stages
          lastStage = fStage <: maximum stages
    , isJust extendedStage'
    , let extendedStage = fStage <: fromJust extendedStage'
    , stage <- (fStage <:) <$> stages
    ]
    ++
    [
      (SuperSource, ProductionVertex $ fLocation <: existing, ExistingEdge $ fInfrastructure <: existing)
    |
      existing <- toKnownRecords existingCube
    ]
    ++
    nub
    [
      (ConsumptionVertex location, SuperSink, DemandEdge location)
    |
      demand <- toKnownRecords demandCube
    , let location = fLocation <: demand
    , (fLocation =: location) `S.member` knownKeys nodeCube
    ]
    ++
    nub
    [
      if productive == Onsite
        then (SuperSource, ConsumptionVertex  location, OnsiteEdge  location $ fTechnology <: production)
        else (SuperSource, ProductionVertex   location, CentralEdge location $ fTechnology <: production)
    |
      production <- toKnownRecords processCostCube
    , let productive = fProductive <: production
    , isProduction productive
    , node <- toKnownRecords nodeCube
    , let location = fLocation <: node
          productive' = fProductive <: node
    , productive == Central && productive' `elem` [Central, Yes] || productive == Onsite && productive' `elem` [Onsite, Yes]
    ]


type TechnologyBuilder = Int -> [Year] -> [Double] -> Maybe TechnologyContext


data TechnologyContext =
  TechnologyContext
  {
    construction :: Construction
  , operation    :: TechnologyOperation
  }


data EdgeContext =
    EdgeContext
    {
      builder    :: Maybe TechnologyBuilder
    , capacity   :: Double
    , reserved   :: [Double]
    , fixed      :: [TechnologyContext]
    , adjustable :: Maybe TechnologyContext
    , flows      :: [Flow]
    , cashes     :: [Cash]
    , impacts    :: [Impact]
    }
  | EdgeReverseContext Edge


data NetworkContext =
  NetworkContext
  {
    edgeContexts :: Map Edge EdgeContext
  }


buildContext :: NetworkGraph -> Network -> ProcessLibrary -> IntensityCube '[FLocation] -> PriceCube '[FLocation] -> DemandCube -> Year -> NetworkContext
buildContext Graph{..} Network{..} processLibrary@ProcessLibrary{..} intensityCube priceCube demandCube year =
  let
    edgeContexts =
      M.fromList
        [
          (
            edge
          , case edge of
              DemandEdge location                       -> EdgeContext
                                                           {
                                                             builder    = Nothing
                                                           , capacity   = maybe 0 (\rec -> fFuelConsumption <: rec + fNonFuelConsumption <: rec) $ demandCube `evaluate` (fLocation =: location <+> fYear =: year)
                                                           , reserved   = [0]
                                                           , fixed      = []
                                                           , adjustable = Nothing
                                                           , flows      = []
                                                           , cashes     = []
                                                           , impacts    = []
                                                           }
              ExistingEdge infrastructure               -> let
                                                             existing = existingCube ! (fInfrastructure =: infrastructure)
                                                           in
                                                             EdgeContext
                                                             {
                                                               builder    = Nothing
                                                             , capacity   = fCapacity <: existing
                                                             , reserved   = [0]
                                                             , fixed      = [
                                                                                TechnologyContext
                                                                                {
                                                                                  construction =     fInfrastructure =: infrastructure
                                                                                                 <+> fLocation       =: fLocation <: existing
                                                                                                 <+> fTechnology     =: Technology "Existing or Planned"
                                                                                                 <+> fProductive     =: Central
                                                                                                 <+> fYear           =: fYear <: existing
                                                                                                 <+> fLifetime       =: 1000
                                                                                                 <+> fNameplate      =: fCapacity <: existing
                                                                                                 <+> fDutyCycle      =: 1
                                                                                                 <+> fLength         =: 0
                                                                                                 <+> fCapitalCost    =: 0
                                                                                                 <+> fFixedCost      =: 0
                                                                                                 <+> fVariableCost   =: fCost <: existing
                                                                                , operation = \year' flow ->
                                                                                                (
                                                                                                      fInfrastructure =: infrastructure
                                                                                                  <+> fYear           =: year'
                                                                                                  <+> fTechnology     =: Technology "Existing or Planned"
                                                                                                  <+> fProduction     =: flow
                                                                                                  <+> fFlow           =: 0
                                                                                                  <+> fLoss           =: 0
                                                                                                  <+> fSale           =: abs flow * fCost <: existing
                                                                                                  <+> fSalvage        =: 0
                                                                                                , [
                                                                                                      fInfrastructure =: infrastructure
                                                                                                    <+> fYear         =: year'
                                                                                                    <+> fCostCategory =: Variable
                                                                                                    <+> fSale         =: abs flow * fCost <: existing
                                                                                                  ]
                                                                                                , []
                                                                                                , flow
                                                                                                )
                                                                                }
                                                                               ]
                                                             , adjustable = Nothing
                                                             , flows      = []
                                                             , cashes     = []
                                                             , impacts    = []
                                                             }
              CentralEdge location technology           -> EdgeContext
                                                           {
                                                             builder    = Just
                                                                            $ \i year' demand ->
                                                                              fmap (uncurry TechnologyContext)
                                                                              $ technologyReifier
                                                                                  processLibrary
                                                                                  (localize intensityCube location)
                                                                                  (makePricer priceCube location)
                                                                                  (fInfrastructure =: Infrastructure ("INFR-" ++ show identifier ++ "-" ++ show (head year') ++ "-" ++ show i) <+> fLocation =: location)
                                                                                  (minimum $ last year' : catMaybes (zipWith (\year'' demand'' -> guard (demand'' /= 0) >> return year'') year' demand))
                                                                                  (foldl mostExtreme 0 demand)
                                                                                  0
                                                                                  technology
                                                           , capacity   = 0
                                                           , reserved   = [0]
                                                           , fixed      = []
                                                           , adjustable = Nothing
                                                           , flows      = []
                                                           , cashes     = []
                                                           , impacts    = []
                                                           }
              OnsiteEdge location technology            -> EdgeContext
                                                           {
                                                             builder    = Just
                                                                            $ \i year' demand ->
                                                                              fmap (uncurry TechnologyContext)
                                                                              $ technologyReifier
                                                                                  processLibrary
                                                                                  (localize intensityCube location)
                                                                                  (makePricer priceCube location)
                                                                                  (fInfrastructure =: Infrastructure ("INFR-" ++ show identifier ++ "-" ++ show (head year') ++ "-" ++ show i) <+> fLocation =: location)
                                                                                  (minimum $ last year' : catMaybes (zipWith (\year'' demand'' -> guard (demand'' /= 0) >> return year'') year' demand))
                                                                                  (foldl mostExtreme 0 demand)
                                                                                  0
                                                                                  technology
                                                           , capacity   = 0
                                                           , reserved   = [0]
                                                           , fixed      = []
                                                           , adjustable = Nothing
                                                           , flows      = []
                                                           , cashes     = []
                                                           , impacts    = []
                                                           }
              PathwayForwardEdge location pathway stage -> let
                                                             technology = fTechnology <: (pathwayCube ! (fPathway =: pathway <+> fStage =: stage))
                                                             (from, distance) =
                                                               if linkCube `evaluable` (fLocation =: location)
                                                                 then let
                                                                        link = linkCube ! (fLocation =: location)
                                                                      in
                                                                        (fFrom <: link, fLength <: link)
                                                                 else (location, 0)
                                                           in
                                                             EdgeContext
                                                             {
                                                               builder    = Just
                                                                              $ \i year' demand ->
                                                                                fmap (uncurry TechnologyContext)
                                                                                $ technologyReifier
                                                                                    processLibrary
                                                                                    (localize intensityCube location)
                                                                                    (makePricer priceCube from)
                                                                                    (fInfrastructure =: Infrastructure ("INFR-" ++ show identifier ++ "-" ++ show (head year') ++ "-" ++ show i) <+> fLocation =: location)
                                                                                    (minimum $ last year' : catMaybes (zipWith (\year'' demand'' -> guard (demand'' /= 0) >> return year'') year' demand))
                                                                                    (foldl mostExtreme 0 demand)
                                                                                    distance
                                                                                    technology
                                                             , capacity   = 0
                                                             , reserved   = [0]
                                                             , fixed      = []
                                                             , adjustable = Nothing
                                                             , flows      = []
                                                             , cashes     = []
                                                             , impacts    = []
                                                             }
              PathwayReverseEdge location pathway stage -> EdgeReverseContext $ PathwayForwardEdge location pathway stage
          )
        |
          (identifier, edge) <- zip [(1::Int)..] $ S.toList allEdges
        ]
  in
    NetworkContext{..}


(.+.) :: Num a => [a] -> [a] -> [a]
(.+.) = zipWith (+)


costEdge :: [Year] -> [Double] -> EdgeContext -> Double
costEdge year delta =
  sum
    . fmap (fSale <:)
    . fst3
    . costEdge' year delta -- FIXME: Handle salvage.


costEdge' :: [Year] -> [Double] -> EdgeContext -> ([Flow], [Cash], [Impact])
costEdge' year delta EdgeContext{..} =
  let
    technologyContexts = (maybe id (:) adjustable) fixed
    (flows', cashes', impacts') = unzip3 . zipWith (\year' flow' -> costTechnologies year' flow' technologyContexts) year $ reserved .+. delta
  in
    (concat flows', concat cashes', concat impacts')
costEdge' _ _ _ = error "costEdge': edge is reversed."


costTechnologies :: Year -> Double -> [TechnologyContext] -> ([Flow], [Cash], [Impact])
costTechnologies year flow technologyContexts=
  let
    (flows', cashes', impacts', _) = -- FIXME: check residue
      foldr (\t (flows'', cashes'', impacts'', residue'') -> let
                                                               (flows''', cashes''', impacts''', residue''') = costTechnology year residue'' t
                                                             in
                                                               (flows''' ++ flows'', cashes''' ++ cashes'', impacts''' ++ impacts'', residue''')
            )
            ([], [], [], flow)
            technologyContexts
  in
    (flows', cashes', impacts')


costTechnology :: Year -> Double -> TechnologyContext -> ([Flow], [Cash], [Impact], Double) -- TODO: Move into operations, which will return flow and residue.
costTechnology year flow TechnologyContext{..} =                                            -- FIXME: Guard against overflow.
  let
    capacity' = fNameplate <: construction * fDutyCycle <: construction
    flow' =
      if abs flow <= capacity'
        then flow
        else signum flow * capacity'
    residue = flow - flow'
    (flows', cashes', impacts', _) = operation year flow'
  in
    ([flows'], cashes', impacts', residue)


sumAbs :: (Num a, Functor t, Foldable t) => t a -> a
sumAbs = sum . fmap abs


marginalCost :: [Year] -> [Double] -> EdgeContext -> Double
marginalCost year delta edgeContext =
  let
    oldCost = costEdge year (const 0 <$> year)                         edgeContext
    newCost = costEdge year (const 0 <$> year) $ adjustEdge year delta edgeContext
  in
    (newCost - oldCost) / sumAbs delta


adjustEdge :: [Year] -> [Double] -> EdgeContext -> EdgeContext
adjustEdge year delta edgeContext@EdgeContext{..} =
  let
    reserved' = reserved .+. delta
    edgeContext' =
      if all ((<= capacity) . abs) reserved' -- FIXME: Rewrite this.
        then edgeContext
             {
               reserved = reserved'
             }
        else let
               adjustable'@TechnologyContext{..} = fromJust $ (fromJust builder) (length fixed + 1) year reserved'
             in
               edgeContext
               {
                 capacity = fNameplate <: construction * fDutyCycle <: construction
               , reserved = reserved'
               , adjustable = Just adjustable'
               }
    (flows', cashes', impacts') = costEdge' year (const 0 <$> year) edgeContext'
  in
    edgeContext'
    {
      flows = flows'
    , cashes = cashes'
    , impacts = impacts'
    }
adjustEdge _ _ _ = error "adjustCapacity: edge is reversed."


makePricer :: PriceCube '[FLocation] -> Location -> Pricer
makePricer priceCube location material year =
  maybe 0 (fPrice <:)
    $ priceCube `evaluate` (fMaterial =: material <+> fYear =: year <+> fLocation =: location) -- FIXME: extrapolate


maximumAbs :: (Num a, Ord a, Functor t, Foldable t) => t a -> a
maximumAbs = maximum . fmap abs


mostExtreme :: (Num a, Ord a) => a -> a -> a
mostExtreme x y =
  if abs x >= abs y
    then x
    else y


data Capacity a = Capacity [a] | Unlimited
  deriving (Read, Show)

instance (RealFloat a, Num a, Ord a) => Eq (Capacity a) where
  Unlimited  == Unlimited  = True
  Unlimited  == Capacity y = all isInfinite y
  Capacity x == Unlimited  = all isInfinite x
  Capacity x == Capacity y = minimum y == minimum x

instance (RealFloat a, Num a, Ord a) => Ord (Capacity a) where
  Unlimited  `compare` Unlimited  = EQ
  Unlimited  `compare` Capacity y = if all isInfinite y then EQ else LT
  Capacity x `compare` Unlimited  = if all isInfinite x then EQ else GT
  Capacity x `compare` Capacity y = minimum y `compare` minimum x

instance Functor Capacity where
  fmap _ Unlimited    = Unlimited
  fmap f (Capacity x) = Capacity $ fmap f x

instance (Num a, Ord a) => Monoid (Capacity a) where
  mempty = Unlimited
  Unlimited  `mappend` Unlimited    = Unlimited
  Unlimited  `mappend` (Capacity y) = Capacity y
  Capacity x `mappend` Unlimited    = Capacity x
  Capacity x `mappend` Capacity y   = Capacity $ minimum [x, y]


costFunction :: [Year] -> Capacity Double -> NetworkContext -> Edge -> Maybe (Sum Double, NetworkContext)
costFunction year (Capacity flow) context edge =
  do
    let
      edgeContext = edgeContexts context M.! edge
      (capacity', builder') =
        case edgeContext of
          EdgeContext{..}          -> (capacity - maximumAbs reserved, builder)
          EdgeReverseContext edge' -> (\z -> capacity z - maximumAbs (reserved z)) &&& builder $ edgeContexts context M.! edge'
      canBuild =  canBuild' year flow builder'
    guard
      $ capacity' > 0 || canBuild
    return
      (
        case edge of
          DemandEdge _                              -> Sum 0
          ExistingEdge _                            -> Sum . sum $ (fVariableCost <:) . construction <$> fixed edgeContext
          PathwayReverseEdge location pathway stage -> fst . fromJust . costFunction year (Capacity (negate <$> flow)) context $ PathwayForwardEdge location pathway stage
          _                                         -> Sum $ marginalCost year flow edgeContext
      , context
      )
costFunction _ _ _ _ = Nothing -- error "costFunction: no flow."


capacityFunction :: [Year] -> NetworkContext -> Edge -> Maybe (Capacity Double, NetworkContext)
capacityFunction year context edge =
  case edgeContexts context M.! edge of
    EdgeContext{..}          -> do
                                  let
                                    canBuild =  canBuild' (take 1 year) [1] builder
                                  guard
                                    $ capacity > maximumAbs reserved || canBuild
                                  return
                                    (
                                      if canBuild
                                        then Capacity $ const inf <$> reserved
                                        else Capacity $ (capacity -) . abs <$> reserved
                                    , context
                                    )
    EdgeReverseContext edge' -> capacityFunction year context edge'


canBuild' :: [Year] -> [Double] -> Maybe TechnologyBuilder -> Bool
canBuild' _    flow Nothing        = maximumAbs flow == 0
canBuild' year flow (Just builder) = isJust $ builder 0 year flow


flowFunction :: [Year] -> Capacity Double -> NetworkContext -> Edge -> Maybe NetworkContext
flowFunction year (Capacity flow) context edge =
  do
    let
      edgeContext = edgeContexts context M.! edge
      update edgeContext' = context { edgeContexts = M.insert edge edgeContext' $ edgeContexts context }
      (capacity', builder') =
        case edgeContext of
          EdgeContext{..}          -> (capacity - maximumAbs reserved, builder)
          EdgeReverseContext edge' -> (\z -> capacity z - maximumAbs (reserved z)) &&& builder $ edgeContexts context M.! edge'
      canBuild =  canBuild' year flow builder'
    guard
      $ capacity' > 0 || canBuild
    return
      $ case edge of
        DemandEdge _                              -> update $ edgeContext { reserved = reserved edgeContext .+. flow}
        ExistingEdge _                            -> update $ let
                                                                (flows', cashes', impacts') = costEdge' year (reserved edgeContext .+. flow) edgeContext -- FIXME: remove head.
                                                              in
                                                                edgeContext
                                                                {
                                                                  reserved = reserved edgeContext .+. flow
                                                                , flows    = flows'
                                                                , cashes   = cashes'
                                                                , impacts  = impacts'
                                                                }
        PathwayReverseEdge location pathway stage -> fromJust . flowFunction year (Capacity (negate <$> flow)) context $ PathwayForwardEdge location pathway stage
        _                                         -> update $ adjustEdge year flow edgeContext
flowFunction _ _ _ _ = error "flowFunction: no flow."


optimize :: SeraLog m => Year -> Network -> DemandCube -> IntensityCube '[FLocation] -> ProcessLibrary -> PriceCube '[FLocation] -> m (Bool, Optimum)
optimize year' network demandCube intensityCube processLibrary priceCube =
  do
    let
      graph = networkGraph network demandCube processLibrary
      context = buildContext graph network processLibrary intensityCube priceCube demandCube year'
      NetworkContext{..} =
        minimumCostFlow
          (costFunction [year'])
          (capacityFunction [year'])
          (flowFunction [year'])
          graph
          context
          SuperSource
          SuperSink
      (constructions', flows', cashes', impacts') =
        unzip4
          $ concat
          [
            case v of
              EdgeContext{..}      -> [
                                        (
                                          construction <$> (maybe id (:) adjustable) fixed
                                        , flows
                                        , cashes
                                        , impacts
                                        )
                                      ] 
              EdgeReverseContext _ -> [] 
          |
            (_, v) <- M.toList edgeContexts
          ]
    logInfo ""
    logInfo $ "Optimizing and checking solution for year " ++ show year' ++ " . . ."
    let
      (existingSupply, totalDemand) =
        (sum *** sum)
          $ unzip
          [
            case k of
              DemandEdge   _ -> (0         , capacity v)
              ExistingEdge _ -> (capacity v, 0         )
              _              -> (0         , 0         )
          |
            (k, v) <- M.toList edgeContexts
          ]
      totalCost =
        sum
          $ concat
          [
            case v of
              EdgeContext{..}      -> (fSale <:) <$> flows
              EdgeReverseContext{} -> []
          |
            (_, v) <- M.toList edgeContexts
          ]
    logNotice $ "Total existing production capacity: " ++ show existingSupply            ++ " kg/yr."
    logNotice $ "Total demand: "                       ++ show totalDemand               ++ " kg."
    logNotice $ "Total cost: "                         ++ show totalDemand               ++ " USD."
    logNotice $ "Average cost: "                       ++ show (totalCost / totalDemand) ++ " USD/kg."
    failure <-
      or <$> sequence
        [
          case k of
            DemandEdge   location -> if capacity v > maximumAbs (reserved v)
                                       then do
                                              logError $ "Unsatisfied demand at \"" ++ show location ++ "\" of " ++ show (capacity v - maximumAbs (reserved v)) ++ " kg/yr."
                                              return True
                                       else return False
            ExistingEdge location -> do
                                       when (capacity v > maximumAbs (reserved v))
                                         . logDebug $ "Underused existing production at \"" ++ show location ++ "\" of " ++ show (capacity v - maximumAbs (reserved v)) ++ " kg/yr."
                                       return False
            _                     -> return False
        |
          (k, v) <- M.toList edgeContexts
        ]
    logInfo $ " . . . checks complete."
    return
      (
        failure
      , Optimum
          (concat constructions')
          (concat flows')
          (concat cashes')
          (concat impacts')
      )
