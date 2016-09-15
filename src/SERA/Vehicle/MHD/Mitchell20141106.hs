-----------------------------------------------------------------------------
--
-- Module      :  SERA.Vocation.MHD.Mitchell20141106
-- Copyright   :  (c) 2016 National Renewable Energy Laboratory
-- License     :  All Rights Reserved
--
-- Maintainer  :  Brian W Bush <brian.bush@nrel.gov>
-- Stability   :  Stable
-- Portability :  Portable
--
-- | Medium and heavy duty vehicle data from George Mitchell of NREL, circa 2014.
--
-----------------------------------------------------------------------------


{-# LANGUAGE DataKinds     #-}
{-# LANGUAGE TypeOperators #-}


module SERA.Vehicle.MHD.Mitchell20141106 (
-- * Vocation types
  vocations
-- * Tabulated functions
, annualTravel
-- * Raw data
, table
) where


import Data.Daft.Vinyl.FieldCube (type (↝), fromRecords)
import Data.Daft.Vinyl.FieldRec.IO (readFieldRecs)
import Data.Vinyl.Derived (FieldRec)
import Data.Vinyl.Lens (rcast)
import SERA.Vehicle.Types (FAge, FAnnualTravel, Vocation(..), FVocation)


-- | Vocation types.
vocations :: [Vocation]
vocations = Vocation . ("Category " ++) . show <$> ['A'..'K']


-- | Annual travel.
annualTravel :: '[FVocation] ↝ '[FAnnualTravel]
annualTravel = fromRecords $ rcast <$> table


-- | Raw data.
table :: [FieldRec '[FVocation, FAge, FAnnualTravel]]
Right table =
  readFieldRecs
    $ ["Vocation", "Age [yr]", "Annual Travel [mi/yr]"]
    : [
        [show classification, show (age - 1), show distance]
      |
        (age, annualTravels) <- raw
      , (classification, distance) <- zip vocations annualTravels
      ]
    :: Either String [FieldRec '[FVocation, FAge, FAnnualTravel]]
    where
      raw :: [(Int, [Double])]
      raw =
        [
          ( 1, [80705, 44027, 30218, 27467, 17642, 15998, 54183, 22357, 20547, 27245, 24868])
        , ( 2, [85152, 46452, 31883, 28981, 18614, 16880, 57169, 23589, 21679, 28746, 26238])
        , ( 3, [86460, 47166, 32373, 29426, 18900, 17139, 58047, 23951, 22012, 29188, 26641])
        , ( 4, [85386, 46580, 31971, 29060, 18665, 16926, 57326, 23654, 21739, 28825, 26310])
        , ( 5, [82571, 45044, 30917, 28102, 18050, 16368, 55436, 22874, 21022, 27875, 25443])
        , ( 6, [78547, 42849, 29410, 26733, 17170, 15570, 52734, 21759, 19998, 26516, 24203])
        , ( 7, [73755, 40235, 27616, 25102, 16123, 14620, 49517, 20432, 18778, 24899, 22726])
        , ( 8, [68546, 37393, 25666, 23329, 14984, 13588, 46020, 18989, 17451, 23140, 21121])
        , ( 9, [63199, 34477, 23663, 21509, 13815, 12528, 42430, 17507, 16090, 21335, 19474])
        , (10, [57926, 31600, 21689, 19715, 12663, 11483, 38890, 16047, 14748, 19555, 17849])
        , (11, [52881, 28848, 19800, 17998, 11560, 10483, 35503, 14649, 13463, 17852, 16294])
        , (12, [48169, 26277, 18036, 16394, 10530,  9549, 32339, 13344, 12264, 16261, 14843])
        , (13, [43854, 23923, 16420, 14925,  9586,  8693, 29442, 12148, 11165, 14805, 13513])
        , (14, [39965, 21802, 14964, 13602,  8736,  7922, 26831, 11071, 10175, 13492, 12315])
        , (15, [36504, 19914, 13668, 12424,  7980,  7236, 24508, 10112,  9294, 12323, 11248])
        , (16, [33452, 18249, 12525, 11385,  7313,  6631, 22459,  9267,  8517, 11293, 10308])
        , (17, [30772, 16787, 11522, 10473,  6727,  6100, 20659,  8524,  7834, 10388,  9482])
        , (18, [28417, 15502, 10640,  9672,  6212,  5633, 19078,  7872,  7235,  9593,  8756])
        , (19, [26335, 14366,  9861,  8963,  5757,  5220, 17681,  7295,  6705,  8890,  8115])
        , (20, [24469, 13348,  9162,  8328,  5349,  4850, 16428,  6778,  6230,  8260,  7540])
        , (21, [22764, 12418,  8523,  7748,  4976,  4513, 15283,  6306,  5796,  7685,  7014])
        , (22, [21171, 11549,  7927,  7205,  4628,  4197, 14214,  5865,  5390,  7147,  6524])
        , (23, [19645, 10717,  7356,  6686,  4294,  3894, 13189,  5442,  5001,  6632,  6053])
        , (24, [18150,  9901,  6796,  6177,  3968,  3598, 12185,  5028,  4621,  6127,  5593])
        , (25, [16662,  9090,  6239,  5671,  3642,  3303, 11186,  4616,  4242,  5625,  5134])
        , (26, [15164,  8272,  5678,  5161,  3315,  3006, 10181,  4201,  3861,  5119,  4673])
        , (27, [13653,  7448,  5112,  4647,  2985,  2706,  9166,  3782,  3476,  4609,  4207])
        , (28, [12136,  6620,  4544,  4130,  2653,  2406,  8148,  3362,  3090,  4097,  3740])
        , (29, [10629,  5798,  3980,  3617,  2323,  2107,  7136,  2944,  2706,  3588,  3275])
        , (30, [ 9159,  4996,  3429,  3117,  2002,  1816,  6149,  2537,  2332,  3092,  2822])
        , (31, [ 7759,  4233,  2905,  2641,  1696,  1538,  5209,  2149,  1975,  2619,  2391])
        , (32, [ 6467,  3528,  2421,  2201,  1414,  1282,  4342,  1791,  1646,  2183,  1993])
        , (33, [ 5324,  2904,  1993,  1812,  1164,  1055,  3574,  1475,  1355,  1797,  1641])
        , (34, [ 4369,  2383,  1636,  1487,   955,   866,  2933,  1210,  1112,  1475,  1346])
        , (35, [ 3363,  1835,  1259,  1145,   735,   667,  2258,   932,   856,  1135,  1036])
        , (36, [ 3363,  1835,  1259,  1145,   735,   667,  2258,   932,   856,  1135,  1036])
        ]
