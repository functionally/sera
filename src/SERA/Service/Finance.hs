{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeOperators              #-}


module SERA.Service.Finance (
  financeMain
) where


import Control.Arrow (first, second)
import Control.Monad.Except (MonadError, MonadIO, liftIO)
import Data.Daft.Vinyl.FieldCube.IO (readFieldCubeSource, writeFieldCubeSource)
import Data.Aeson (FromJSON(parseJSON), ToJSON(toJSON), withText, defaultOptions, genericToJSON)
import Data.Daft.Source (DataSource(..), withSource)
import Data.Default.Util (zero, nan)
import Data.Daft.DataCube (evaluate)
import Data.Daft.Vinyl.FieldRec ((<+>), (=:), (<:))
import Data.Daft.Vinyl.FieldCube -- (type (↝), π, σ)
import Data.Function (on)
import Data.List (groupBy, intercalate, sortBy, transpose, zipWith4)
import Data.List.Split (splitOn)
import Data.Table (Tabulatable(..))
import Data.Maybe (fromMaybe)
import Data.String (IsString)
import Data.String.ToString (toString)
import Data.Vinyl.Derived (FieldRec, SField(..))
import Data.Void (Void)
import Debug.Trace (trace)
import GHC.Generics (Generic)
import SERA.Configuration.ScenarioInputs (ScenarioInputs(..))
import SERA.Energy (EnergyCosts(..))
import SERA.Service.HydrogenSizing -- (StationSummaryCube)
import SERA.Finance.Analysis (computePerformanceAnalyses)
import SERA.Finance.Analysis.CashFlowStatement (CashFlowStatement(..))
import SERA.Finance.Analysis.Finances (Finances(..))
import SERA.Finance.Analysis.PerformanceAnalysis (PerformanceAnalysis)
import SERA.Finance.Capital (Capital(..), Operations(..), costStation)
import SERA.Refueling.FCVSE.Cost.NREL56412 (rentCost, totalFixedOperatingCost)
import SERA.Finance.IO.Xlsx (formatResultsAsFile)
import SERA.Finance.Scenario (Scenario(..))
import SERA.Finance.Solution (solveConstrained')
import SERA.Service ()
import SERA.Vehicle.Types
import SERA.Types
import SERA.Util.Summarization (summation)


data Inputs =
  Inputs
    {
      scenario       :: ScenarioInputs
    , station        :: Capital
    , operations     :: Operations
    , feedstockUsageSource :: DataSource Void
    , energyPricesSource  :: DataSource Void
    , carbonCreditSource :: DataSource Void
    , stationsSummarySource :: DataSource Void
    , stationsDetailsSource :: DataSource Void
    , financesDirectory :: FilePath
    , financesSpreadsheet     :: FilePath
    , financesFile    :: FilePath
    , targetMargin   :: Maybe Double
    }
    deriving (Generic, Read, Show)

instance FromJSON Inputs

instance ToJSON Inputs where
  toJSON = genericToJSON defaultOptions


newtype HydrogenSource = HydrogenSource {hydrogenSource :: String}
  deriving (Eq, Ord)

instance Read HydrogenSource where
  readsPrec
    | quotedStringTypes = (fmap (first HydrogenSource) .) . readsPrec
    | otherwise         = const $ return . (, []) . HydrogenSource

instance Show HydrogenSource where
  show
    | quotedStringTypes = show . hydrogenSource
    | otherwise         = hydrogenSource

instance FromJSON HydrogenSource where
  parseJSON = withText "HydrogenSource" $ return . HydrogenSource . toString

instance ToJSON HydrogenSource where
  toJSON = toJSON . hydrogenSource

type FHydrogenSource = '("Hydrogen Source", HydrogenSource)

fHydrogenSource :: SField FHydrogenSource
fHydrogenSource = SField

newtype FeedstockType = FeedstockType {feedstockType :: String}
  deriving (Eq, Ord)

instance Read FeedstockType where
  readsPrec
    | quotedStringTypes = (fmap (first FeedstockType) .) . readsPrec
    | otherwise         = const $ return . (, []) . FeedstockType

instance Show FeedstockType where
  show
    | quotedStringTypes = show . feedstockType
    | otherwise         = feedstockType

instance FromJSON FeedstockType where
  parseJSON = withText "FeedstockType" $ return . FeedstockType . toString

instance ToJSON FeedstockType where
  toJSON = toJSON . feedstockType

type FFeedstockType = '("Feedstock", FeedstockType)

fFeedstockType :: SField FFeedstockType
fFeedstockType = SField

type FFeedstockUsage = '("Feedstock Usage [/kg]", Double)

fFeedstockUsage :: SField FFeedstockUsage
fFeedstockUsage = SField

type FeedstockUsageCube = '[FHydrogenSource, FFeedstockType] ↝ '[FFeedstockUsage]


type FStationUtilization = '("Utilization [kg/kg]", Double)

fStationUtilization :: SField FStationUtilization
fStationUtilization = SField


type FNonRenewablePrice = '("Non-Renewable Price [$]", Double)

fNonRenewablePrice :: SField FNonRenewablePrice
fNonRenewablePrice = SField

type FRenewablePrice = '("Renewable Price [$]", Double)

fRenewablePrice :: SField FRenewablePrice
fRenewablePrice = SField


type EnergyPriceCube = '[FYear, FFeedstockType] ↝ '[FNonRenewablePrice, FRenewablePrice]


type StationUtilizationCube = '[FYear, FRegion] ↝ '[FStationUtilization]


type FNonRenewableCredit = '("Carbon Credit (Non-Renewable) [$/kg]", Double)

fNonRenewableCredit :: SField FNonRenewableCredit
fNonRenewableCredit = SField


type FRenewableCredit = '("Carbon Credit (Renewable) [$/kg]", Double)

fRenewableCredit :: SField FRenewableCredit
fRenewableCredit = SField

type CarbonCreditCube = '[FHydrogenSource] ↝ '[FNonRenewableCredit, FRenewableCredit]


computeRegionalUtilization :: StationSummaryCube -> StationUtilizationCube
computeRegionalUtilization =
  let
    utilization :: k -> FieldRec '[FSales, FStock, FTravel, FEnergy, FDemand, FNewStations, FTotalStations, FNewCapacity, FTotalCapacity] -> FieldRec '[FStationUtilization]
    utilization _ rec =
      fStationUtilization =: fDemand <: rec / fTotalCapacity <: rec
  in
    π utilization


financeMain :: (IsString e, MonadError e m, MonadIO m)
                       => Inputs -- ^ Configuration data.
                       -> m ()               -- ^ Action to compute the introduction years.
financeMain parameters@Inputs{..}=
  do
    feedstockUsage <- readFieldCubeSource feedstockUsageSource
    energyPrices <- readFieldCubeSource energyPricesSource
    carbonCredits <- readFieldCubeSource carbonCreditSource
    stationsSummary <- readFieldCubeSource stationsSummarySource
    stationsDetail <- readFieldCubeSource stationsDetailsSource
    let
      regionalUtilization = computeRegionalUtilization stationsSummary
      inputs' = makeInputs parameters feedstockUsage energyPrices carbonCredits regionalUtilization stationsDetail
      ids = map ((\(reg, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) -> reg) . head) inputs'
      prepared = map (prepareInputs parameters) inputs'
      prepared' = case targetMargin of
        Nothing     -> prepared
        Just margin -> let
                         refresh prepared'' =
                           let
                             (_, allOutputs') = multiple parameters prepared''
                             prices = findHydrogenPrice margin allOutputs'
                           in
                             map (setHydrogenPrice prices) prepared''
                       in
                         (refresh . refresh . refresh . refresh . refresh . refresh . refresh . refresh . refresh . refresh) prepared
      (outputs, allOutputs) = multiple parameters prepared'
    liftIO $ sequence_
      [
        formatResultsAsFile outputFile' $ dumpOutputs' output
      |
        (idx, output) <- zip ids outputs
      , let outputFile' = financesDirectory ++ "/finances-" ++ idx ++ ".xlsx"
      ]
    liftIO $ formatResultsAsFile financesSpreadsheet $ dumpOutputs' allOutputs
    liftIO $ writeFile financesFile $ dumpOutputs9 allOutputs


multiple :: Inputs -> [[(Capital, Scenario)]] -> ([Outputs], Outputs)
multiple parameters capitalScenarios =
  let
    firstYear = minimum $ map (stationYear . fst . head) capitalScenarios
    outputs = map (single parameters) capitalScenarios
    outputs' = outputs
    scenarioDefinition'= scenario parameters
    stations'  = map summation $ transpose $ map (padStations firstYear  . stations ) outputs'
    scenarios' = map summation $ transpose $ map (padScenarios firstYear . scenarios) outputs'
    finances'  = map summation $ transpose $ map (padFinances firstYear  . finances ) outputs'
    performances' = computePerformanceAnalyses scenarioDefinition' $ zip scenarios' finances'
  in
    (
      outputs'
    , JSONOutputs
      {
        scenarioDefinition = scenarioDefinition'
      , stations           = stations'
      , scenarios          = scenarios'
      , finances           = finances'
      , analyses           = performances'
      }
    )


setHydrogenPrice :: [(Int, Double)] -> [(Capital, Scenario)] -> [(Capital, Scenario)]
setHydrogenPrice prices =
  map (second $ setHydrogenPrice' prices)


setHydrogenPrice' :: [(Int, Double)] -> Scenario -> Scenario
setHydrogenPrice' prices scenario =
  scenario
  {
    hydrogenPrice =
      let
        price = fromMaybe (read "NaN") $ scenarioYear scenario `lookup` prices
      in
        if isNaN price
          then hydrogenPrice scenario
          else price
  }


findHydrogenPrice :: Double -> Outputs -> [(Int, Double)]
findHydrogenPrice offset outputs =
  let
    year = map scenarioYear $ scenarios outputs
    price = map hydrogenPrice $ scenarios outputs
    sales = map hydrogenSales $ scenarios outputs
    income = map (netIncome . cashFlowStatement) $ finances outputs
  in
    zipWith4 (\y p s i -> (y, p + offset - i / 365 / s)) year price sales income


padStations :: Int -> [Capital] -> [Capital]
padStations year ss = zipWith (\y s -> s {stationYear = y}) [year..] (replicate (stationYear (head ss) - year) zero) ++ ss


padScenarios :: Int -> [Scenario] -> [Scenario]
padScenarios year ss = zipWith (\y s -> s {scenarioYear = y}) [year..] (replicate (scenarioYear (head ss) - year) zero) ++ ss


padFinances :: Int -> [Finances] -> [Finances]
padFinances year fs = zipWith (\y s -> s {financesYear = y}) [year..] (replicate (financesYear (head fs) - year) zero) ++ fs


single :: Inputs -> [(Capital, Scenario)] -> Outputs
single parameters capitalScenarios =
  let
    (_scenarios, finances, performances) = solveConstrained' (scenario parameters) capitalScenarios
  in
    JSONOutputs
    {
      scenarioDefinition = scenario parameters
    , stations           = map fst capitalScenarios
    , scenarios          = map snd capitalScenarios
    , finances           = finances
    , analyses           = performances
    }


makeInputs :: Inputs -> FeedstockUsageCube -> EnergyPriceCube -> CarbonCreditCube -> StationUtilizationCube -> StationDetailCube -> [[(String, String, Int, Int, Int, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double)]]
makeInputs parameters feedstockUsage energyPrices carbonCredits stationUtilization stationsDetail =
  let
    makeInputs' :: (Region, StationID, Maybe Int, Int, Double, Double, Double, Double, Double, Double) -> [FieldRec '[FRegion, FYear, FStationID, FNewCapitalCost, FNewInstallationCost, FNewCapitalIncentives, FNewProductionIncentives, FNewElectrolysisCapacity, FNewPipelineCapacity, FNewOnSiteSMRCapacity, FNewGH2TruckCapacity, FNewLH2TruckCapacity, FRenewableFraction]] -> [(String, String, Int, Int, Int, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double)]
    makeInputs' (region', station', previousYear, totalStations', electrolysisCapacity', pipelineCapacity', onSiteSMRCapacity', gh2TruckCapacity', lh2TruckCapacity', renewableCapacity') []           =
      let
        Just nextYear = (+1) <$> previousYear
        year = 2051
      in
        if nextYear >= year
          then
            []
          else
            makeInputs'
              (region', station', previousYear, totalStations', electrolysisCapacity', pipelineCapacity', onSiteSMRCapacity', gh2TruckCapacity', lh2TruckCapacity', renewableCapacity')
              (
                (
                    fRegion =: region'
                <+> fYear   =: nextYear
                <+> fStationID =: station'
                <+> fNewCapitalCost =: 0
                <+> fNewInstallationCost =: 0
                <+> fNewCapitalIncentives =: 0
                <+> fNewProductionIncentives =: 0
                <+> fNewElectrolysisCapacity =: 0
                <+> fNewPipelineCapacity =: 0
                <+> fNewOnSiteSMRCapacity =: 0
                <+> fNewGH2TruckCapacity =: 0
                <+> fNewLH2TruckCapacity =: 0
                <+> fRenewableFraction =: 0
                )
                : []
              )
    makeInputs' (_, _, previousYear, totalStations', electrolysisCapacity', pipelineCapacity', onSiteSMRCapacity', gh2TruckCapacity', lh2TruckCapacity', renewableCapacity') (rec : recs) =
      let
        region' = fRegion <: rec
        station' = fStationID <: rec 
        Just nextYear = (+1) <$> previousYear
        newElectrolysis = fNewElectrolysisCapacity <: rec
        newPipeline = fNewPipelineCapacity <: rec
        newOnSiteSMR = fNewOnSiteSMRCapacity <: rec
        newGH2Truck = fNewGH2TruckCapacity <: rec
        newLH2Truck = fNewLH2TruckCapacity <: rec
        newCapacity = newElectrolysis + newPipeline + newOnSiteSMR + newGH2Truck + newLH2Truck
        renewableCapacity = renewableCapacity' + newCapacity * (fRenewableFraction <: rec)
        renewableFraction = renewableCapacity / totalCapacity
        year = fYear <: rec
        totalStations = totalStations' + newStations
        newStations = if newCapacity > 0 then 1 else 0
        electrolysisCapacity = electrolysisCapacity' + newElectrolysis
        pipelineCapacity = pipelineCapacity' + newPipeline
        onSiteSMRCapacity = onSiteSMRCapacity' + newOnSiteSMR
        gh2TruckCapacity = gh2TruckCapacity' + newGH2Truck
        lh2TruckCapacity = lh2TruckCapacity' + newLH2Truck
        electricityUse = (
                           ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Electrolysis" <+> fFeedstockType =: FeedstockType "Electricity [kWh]"  )) * electrolysisCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Pipeline"     <+> fFeedstockType =: FeedstockType "Electricity [kWh]"  )) * pipelineCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "On-Site SMR"  <+> fFeedstockType =: FeedstockType "Electricity [kWh]"  )) * onSiteSMRCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Trucked GH2"  <+> fFeedstockType =: FeedstockType "Electricity [kWh]"  )) * gh2TruckCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Trucked LH2"  <+> fFeedstockType =: FeedstockType "Electricity [kWh]"  )) * lh2TruckCapacity
                         ) / totalCapacity
        naturalGasUse  = (
                           ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Electrolysis" <+> fFeedstockType =: FeedstockType "Natural Gas [mmBTU]")) * electrolysisCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Pipeline"     <+> fFeedstockType =: FeedstockType "Natural Gas [mmBTU]")) * pipelineCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "On-Site SMR"  <+> fFeedstockType =: FeedstockType "Natural Gas [mmBTU]")) * onSiteSMRCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Trucked GH2"  <+> fFeedstockType =: FeedstockType "Natural Gas [mmBTU]")) * gh2TruckCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Trucked LH2"  <+> fFeedstockType =: FeedstockType "Natural Gas [mmBTU]")) * lh2TruckCapacity
                         ) / totalCapacity
        hydrogenUse    = (
                           ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Electrolysis" <+> fFeedstockType =: FeedstockType "Hydrogen [kg]"      )) * electrolysisCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Pipeline"     <+> fFeedstockType =: FeedstockType "Hydrogen [kg]"      )) * pipelineCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "On-Site SMR"  <+> fFeedstockType =: FeedstockType "Hydrogen [kg]"      )) * onSiteSMRCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Trucked GH2"  <+> fFeedstockType =: FeedstockType "Hydrogen [kg]"      )) * gh2TruckCapacity
                         + ((fFeedstockUsage <:) $ feedstockUsage ! (fHydrogenSource =: HydrogenSource "Trucked LH2"  <+> fFeedstockType =: FeedstockType "Hydrogen [kg]"      )) * lh2TruckCapacity
                         ) / totalCapacity
        totalCapacity = electrolysisCapacity + pipelineCapacity + onSiteSMRCapacity + gh2TruckCapacity + lh2TruckCapacity
        capitalCost = fNewCapitalCost <: rec
        installationCost = fNewInstallationCost <: rec
        capitalGrant = fNewCapitalIncentives <: rec
        operatingGrant = fNewProductionIncentives <: rec
        incidentalRevenue = nan -- FIXME
        electricity = ((fNonRenewablePrice <:) $ energyPrices ! (fYear =: year <+> fFeedstockType =: FeedstockType "Electricity [/kWh]"   )) * (1 - renewableFraction)
                    + ((fRenewablePrice    <:) $ energyPrices ! (fYear =: year <+> fFeedstockType =: FeedstockType "Electricity [/kWh]"   )) *      renewableFraction
        naturalGas  = ((fNonRenewablePrice <:) $ energyPrices ! (fYear =: year <+> fFeedstockType =: FeedstockType "Natural Gas [/mmBTU]" )) * (1 - renewableFraction)
                    + ((fRenewablePrice    <:) $ energyPrices ! (fYear =: year <+> fFeedstockType =: FeedstockType "Natural Gas [/mmBTU]" )) *      renewableFraction
        deliveredH2 = ((fNonRenewablePrice <:) $ energyPrices ! (fYear =: year <+> fFeedstockType =: FeedstockType "Hydrogen [/kg]"       )) * (1 - renewableFraction)
                    + ((fRenewablePrice    <:) $ energyPrices ! (fYear =: year <+> fFeedstockType =: FeedstockType "Hydrogen [/kg]"       )) *      renewableFraction
        retailH2    = ((fNonRenewablePrice <:) $ energyPrices ! (fYear =: year <+> fFeedstockType =: FeedstockType "Retail Hydrogen [/kg]")) * (1 - renewableFraction)
                    + ((fRenewablePrice    <:) $ energyPrices ! (fYear =: year <+> fFeedstockType =: FeedstockType "Retail Hydrogen [/kg]")) *      renewableFraction
        demand = (totalCapacity *) . maybe 0 (fStationUtilization <:) $ stationUtilization `evaluate` τ rec
        carbonCreditPerKg = (
                              ((fNonRenewableCredit <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "Electrolysis")) * electrolysisCapacity
                            + ((fNonRenewableCredit <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "Pipeline"    )) * pipelineCapacity
                            + ((fNonRenewableCredit <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "On-Site SMR" )) * onSiteSMRCapacity
                            + ((fNonRenewableCredit <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "Trucked GH2" )) * gh2TruckCapacity
                            + ((fNonRenewableCredit <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "Trucked LH2" )) * lh2TruckCapacity
                            ) / totalCapacity * (1 - renewableFraction)
                            +
                            (
                              ((fRenewableCredit    <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "Electrolysis")) * electrolysisCapacity
                            + ((fRenewableCredit    <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "Pipeline"    )) * pipelineCapacity
                            + ((fRenewableCredit    <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "On-Site SMR" )) * onSiteSMRCapacity
                            + ((fRenewableCredit    <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "Trucked GH2" )) * gh2TruckCapacity
                            + ((fRenewableCredit    <:) $ carbonCredits ! (fHydrogenSource =: HydrogenSource "Trucked LH2" )) * lh2TruckCapacity
                            ) / totalCapacity *      renewableFraction
      in
        if previousYear == Nothing || nextYear == year
          then
            (
              show $ fStationID <: rec
            , undefined
            , year
            , totalStations
            , newStations
            , electricityUse
            , naturalGasUse
            , hydrogenUse
            , totalCapacity
            , capitalCost
            , installationCost
            , incidentalRevenue
            , capitalGrant
            , operatingGrant
            , electricity
            , naturalGas
            , deliveredH2
            , retailH2
            , demand
            , carbonCreditPerKg
            )
            : makeInputs' (region', station', Just year, totalStations, electrolysisCapacity, pipelineCapacity, onSiteSMRCapacity, gh2TruckCapacity, lh2TruckCapacity, renewableCapacity) recs
          else
            makeInputs'
              (region', station', previousYear, totalStations', electrolysisCapacity', pipelineCapacity', onSiteSMRCapacity', gh2TruckCapacity', lh2TruckCapacity', renewableCapacity')
              (
                (
                    fRegion =: fRegion <: rec
                <+> fYear   =: nextYear
                <+> fStationID =: fStationID <: rec
                <+> fNewCapitalCost =: 0
                <+> fNewInstallationCost =: 0
                <+> fNewCapitalIncentives =: 0
                <+> fNewProductionIncentives =: 0
                <+> fNewElectrolysisCapacity =: 0
                <+> fNewPipelineCapacity =: 0
                <+> fNewOnSiteSMRCapacity =: 0
                <+> fNewGH2TruckCapacity =: 0
                <+> fNewLH2TruckCapacity =: 0
                <+> fRenewableFraction =: 0
                )
                : rec : recs
              )
  in
    map (makeInputs' (undefined, undefined, Nothing, 0, 0, 0, 0, 0, 0, 0))
      $ groupBy ((==) `on` (\rec -> (fRegion <: rec, fStationID <: rec)))
      $ sortBy (compare `on` (\rec -> (fRegion <: rec, fStationID <: rec, fYear <: rec)))
      $ toKnownRecords stationsDetail


prepareInputs :: Inputs -> [(String, String, Int, Int, Int, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double, Double)] -> [(Capital, Scenario)]
prepareInputs parameters inputs =
  let
    firstYear :: Int
    (_, _, firstYear, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = head inputs
    capitalScenarios :: [(Capital, Scenario)]
    capitalScenarios =
      [
        (
          (\c@Station{..} ->
            let
              totalStations' = fromIntegral totalStations 
              averageCapacity = totalCapacity / totalStations'
              escalation = 1.019**(fromIntegral stationYear - 2016)
            in
              c {
                  stationLicensingAndPermitting = totalStations' * stationLicensingAndPermitting
                , stationMaintenanceCost        = escalation * totalStations' * (totalFixedOperatingCost averageCapacity - rentCost averageCapacity)
                , stationRentOfLand             = escalation * totalStations' * rentCost averageCapacity
                , stationIncidentalRevenue      = stationIncidentalRevenue + carbonCredits * 365.24 * demand * escalation
                }
          ) $ costStation 0 (operations parameters) (year) $ (station parameters)
          {
            stationYear                            = year
          , stationTotal                           = totalStations
          , stationOperating                       = fromIntegral totalStations - fromIntegral newStations / 2
          , stationNew                             = newStations
          , stationElectricityUse                  = electricityUse
          , stationNaturalGasUse                   = naturalGasUse
          , stationDeliveredHydrogenUse            = hydrogenUse
          , stationCapacity                        = totalCapacity
          , stationCapitalCost                     = capitalCost
          , stationInstallationCost                = installationCost
          , stationIncidentalRevenue               = incidentalRevenue
--        , stationMaintenanceCost                 = read "NaN"
--        , stationLicensingAndPermitting          = read "NaN"
--        , stationRentOfLand                      = read "NaN"
--        , stationStaffing                        = read "NaN"
--        , stationLaborRate                       = read "NaN"
--        , stationSellingAndAdministrativeExpense = read "NaN"
--        , stationCreditCardFeesRate              = read "NaN"
--        , stationSalesTaxRate                    = read "NaN"
--        , stationRoadTax                         = read "NaN"
--        , stationPropertyTaxRate                 = read "NaN"
--        , stationPropertyInsuranceRate           = read "NaN"
          }
        , Scenario
          {
            scenarioYear               = year
          , durationOfDebt             = year - firstYear + 1
          , newCapitalIncentives       = capitalGrant
          , newProductionIncentives    = operatingGrant
          , newFuelPrepayments         = 0
          , newCrowdFunding            = 0
          , newConsumerDiscounts       = 0
          , newCapitalExpenditures     = capitalCost
          , electricityCost            = electricity
          , naturalGasCost             = naturalGas
          , hydrogenCost               = deliveredH2
          , hydrogenPrice              = retailH2
          , stationUtilization         = demand / totalCapacity
          , hydrogenSales              = demand
          , fcevTotal                  = 0
          , fcevNew                    = 0
          , economyNet                 = read "NaN"
          , economyNew                 = read "NaN"
          , vmtTotal                   = read "NaN"
          }
        )
      |
        (_regionId, _regionName, year, totalStations, newStations, electricityUse, naturalGasUse, hydrogenUse, totalCapacity, capitalCost, installationCost, incidentalRevenue, capitalGrant, operatingGrant, electricity, naturalGas, deliveredH2, retailH2, demand, carbonCredits) <- inputs
      , (totalStations :: Int) > 0
      ]
  in
    accumulateMaintenanceCosts 0
      $ extendTo2050
      $ replicateFirstYear capitalScenarios


accumulateMaintenanceCosts :: Double -> [(Capital, Scenario)] -> [(Capital, Scenario)]
accumulateMaintenanceCosts _        [] = []
accumulateMaintenanceCosts previous ((c, s) : css) =
  (c {stationMaintenanceCost = alpha * stationMaintenanceCost c + beta * 0.05 * cumulativeCapitalCost}, s)
    : accumulateMaintenanceCosts cumulativeCapitalCost css
    where
      alpha = maximum [0, minimum [1, (2025 - fromIntegral (stationYear c)) / (2025 - 2015)]]
      beta = 1 - alpha
      cumulativeCapitalCost = 1.019 * previous + stationCapitalCost c


replicateFirstYear :: [(Capital, Scenario)] -> [(Capital, Scenario)]
replicateFirstYear ((c, s) : css) =
  (
    c
    {
      stationYear              = stationYear c - 1
    , stationOperating         = 0
    , stationMaintenanceCost   = 0
    , stationIncidentalRevenue = 0
    }
  , s
    {
      scenarioYear       = scenarioYear s - 1
    , durationOfDebt     = durationOfDebt s - 1
    , stationUtilization = 0
    , hydrogenSales      = 0
    }
  )
  :
  (
    c
    {
      stationNew              = 0
    , stationCapitalCost      = 0
    , stationInstallationCost = 0
    }
  , s
    {
      newCapitalIncentives   = 0
    , newCapitalExpenditures = 0
    }
  )
  : css
replicateFirstYear _ = undefined


extendTo2050 :: [(Capital, Scenario)] -> [(Capital, Scenario)]
extendTo2050 [] = []
extendTo2050 [cs@(c, s)] =
  cs :
    if stationYear (fst cs) >= 2050
      then []
      else
        extendTo2050
        [
          (
            c
            {
              stationYear                   = 1 + stationYear c
            , stationOperating              = fromIntegral $ stationTotal c
            , stationNew                    = 0
            , stationCapitalCost            = 0
            , stationInstallationCost       = 0
            , stationIncidentalRevenue      = 1.019 * stationIncidentalRevenue c
            , stationMaintenanceCost        = 1.019 * stationMaintenanceCost c
            , stationLicensingAndPermitting = 1.019 * stationLicensingAndPermitting c
            , stationRentOfLand             = 1.019 * stationRentOfLand c
            , stationLaborRate              = 1.019 * stationLaborRate c
            }
          , s
            {
              scenarioYear            = 1 + scenarioYear s
            , durationOfDebt          = 1 + durationOfDebt s
            , newCapitalIncentives    = 0
            , newProductionIncentives = 0
            , newCapitalExpenditures  = 0
            , electricityCost         = 1.019 * electricityCost s
            , naturalGasCost          = 1.019 * naturalGasCost s
            , hydrogenCost            = 1.019 * hydrogenCost s
            , hydrogenPrice           = 1.019 * hydrogenPrice s
            , stationUtilization      = (0.75 + stationUtilization s) / 2
            , hydrogenSales           = (0.75 * stationCapacity c + hydrogenSales s) / 2
            }
          )
        ]
extendTo2050 (cs : css) = cs : extendTo2050 css


data Outputs =
    JSONOutputs
    {
      scenarioDefinition :: ScenarioInputs
    , stations           :: [Capital]
    , scenarios          :: [Scenario]
    , finances           :: [Finances]
    , analyses           :: [PerformanceAnalysis]
    }
  | TSVOutputs
    {
      scenarioDefinitionTSV :: String
    , stationsTSV           :: String
    , scenariosTSV          :: String
    , financesTSV           :: String
    , analysesTSV           :: String
    }
    deriving (Generic, Read, Show)

instance FromJSON Outputs

instance ToJSON Outputs where
  toJSON = genericToJSON defaultOptions


makeTSVOutputs :: Outputs -> Outputs
makeTSVOutputs JSONOutputs{..} =
  TSVOutputs
    {
      scenarioDefinitionTSV = tabulationsT' [scenarioDefinition]
    , stationsTSV           = tabulationsT' stations
    , scenariosTSV          = tabulationsT' scenarios
    , financesTSV           = tabulationsT' finances
    , analysesTSV           = tabulationsT' analyses
    }
makeTSVOutputs o@TSVOutputs{} = o


dumpOutputs9 :: Outputs -> String
dumpOutputs9 outputs =
  let
    TSVOutputs{..} = makeTSVOutputs outputs
    basic =
      map (splitOn "\t")
      $ lines
      $ unlines
      [
        scenarioDefinitionTSV
      , ""
      , stationsTSV
      , ""
      , scenariosTSV
      , ""
      , financesTSV
      , ""
      , analysesTSV
      ]
    n = maximum $ map length basic
    pad x = take n $ x ++ repeat (if null x then [] else last x)
  in
    unlines
      $ map (intercalate "\t")
      $ transpose
      $ map pad
      basic


dumpOutputs' :: Outputs -> [[String]]
dumpOutputs' outputs =
  let
    TSVOutputs{..} = makeTSVOutputs outputs
  in
    map (splitOn "\t") $ lines $ unlines
      [
        scenarioDefinitionTSV
      , ""
      , stationsTSV
      , ""
      , scenariosTSV
      , ""
      , financesTSV
      , ""
      , analysesTSV
      ]
