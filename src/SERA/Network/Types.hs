{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeOperators              #-}


module SERA.Network.Types (
-- * Data types
  Location(..)
, Zone(..)
, Path(..)
, Node
, Link
-- * Field types
, FLocation
, FZone
, FX
, FY
, FArea
, FSale
, FRent
, FFrom
, FTo
, FLength
, FTerritory
-- * Field accessors
, fLocation
, fZone
, fX
, fY
, fArea
, fSale
, fRent
, fFrom
, fTo
, fLength
, fTerritory
-- * Types
, Network(..)
-- * Data cubes
, NodeCube
, LinkCube
, ExistingCube
, TerritoryCube
, ZoneCube
) where


import Data.Daft.Vinyl.FieldCube (type (*↝))
import Data.Vinyl.Derived (FieldRec)
import SERA.Process.Types (FCapacity, FCost, FDelivery, FProductive, FTransmission, FYield)
import SERA.Types (FFraction, FYear)
import SERA.Types.TH (makeField, makeStringField)


$(makeStringField "Location"    "Network ID"                 )
$(makeField       "From"        "From Node ID"     ''Location)
$(makeField       "To"          "To Node ID"       ''Location)
$(makeField       "X"           "X"                ''Double  )
$(makeField       "Y"           "Y"                ''Double  )
$(makeField       "Area"        "Area [km^2]"      ''Double  )
$(makeField       "Length"      "Length [km]"      ''Double  )
$(makeField       "Sale"        "Cost [$]"         ''Double  )
$(makeField       "Rent"        "Cost [$/yr]"      ''Double  )
$(makeStringField "Territory"   "Territory"                  )
$(makeStringField "Zone"        "Zone"                       )


data Network =
  Network
  {
    nodeCube :: NodeCube
  , linkCube :: LinkCube
  , existingCube :: ExistingCube
  , territoryCube :: TerritoryCube
  , zoneCube :: ZoneCube '[FLocation]
  }
    deriving (Eq, Ord, Show)


type NodeCube = '[FLocation] *↝ '[FX, FY, FArea, FProductive, FSale, FRent]


type LinkCube = '[FLocation] *↝ '[FFrom, FTo, FLength, FSale, FRent, FTransmission, FDelivery]


type ExistingCube = '[FLocation] *↝ '[FYear, FCapacity, FYield, FCost]


type TerritoryCube = '[FTerritory, FLocation] *↝ '[FFraction]


type ZoneCube key = (FZone ': key) *↝ '[FFraction]


type Node = FieldRec '[FLocation, FX, FY, FArea, FProductive, FSale, FRent]


type Link = FieldRec '[FLocation, FFrom, FTo, FLength, FSale, FRent, FTransmission, FDelivery]


data Path =
    TransmissionPath -- FIXME: Enforce semantics.
    {
      sourceId        :: Location
    , transmissionIds :: [(Location, Double)]
    , gateId          :: Location
    }
  | DeliveryPath -- FIXME: Enforce semantics.
    {
      gateId          :: Location
    , deliveryIds     :: [(Location, Double)]
    , sinkId          :: Location
    }
  | FullPath -- FIXME: Enforce semantics.
    {
      sourceId        :: Location
    , transmissionIds :: [(Location, Double)]
    , gateId          :: Location
    , deliveryIds     :: [(Location, Double)]
    , sinkId          :: Location
    }
  | GenericPath -- FIXME: Enforce semantics.
    {
      sourceId        :: Location
    , linkIds         :: [(Location, Double)]
    , sinkId          :: Location
    }
    deriving (Eq, Ord, Read, Show)
