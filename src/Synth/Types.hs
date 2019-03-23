{-# LANGUAGE TemplateHaskell #-}
module Synth.Types
  ( Layer(..)
  , layerSource
  , layerBeat
  , layerCellPrefix
  , layerSourcePrefix
  ) where

import Control.Lens (makeLenses)
import Synth.Newtypes (Cell, Sample)

data Layer =
  Layer
    { _layerSource :: ![Sample]
    , _layerBeat :: ![Cell]
    , _layerCellPrefix :: !Cell
    , _layerSourcePrefix :: ![Sample]
    }

makeLenses ''Layer
