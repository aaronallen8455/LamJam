{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE BangPatterns #-}
module Jambda.Data.Layer
  ( newLayer
  , readChunk
  , getSamples
  , syncLayer
  , resetLayer
  , applyLayerBeatChange
  , applyLayerOffsetChange
  , applyLayerSourceChange
  ) where

import            Control.Lens hiding ((:>))
import            Control.Monad (guard)
import            Control.Monad.Trans.Maybe (MaybeT(..), runMaybeT)
import            Control.Monad.IO.Class (liftIO)
import            Data.Stream.Infinite (Stream(..))
import qualified  Data.Stream.Infinite as Stream
import            Data.IORef (readIORef, modifyIORef')
import            Data.Maybe (isJust)

import            Jambda.Data.Constants (taperLength)
import            Jambda.Data.Conversions (numSamplesForCellValue, numSamplesToCellValue)
import            Jambda.Data.Parsers (parseBeat, parseOffset, parsePitch)
import            Jambda.Data.Stream (dovetail, linearTaper, silence, sineWave)
import            Jambda.Types
import            Jambda.UI.Editor (getEditorContents)

-- | Create a new layer with the given Pitch using defaults
-- for all other fields
newLayer :: Pitch -> Layer
newLayer pitch = Layer
  { _layerSource = source
  , _layerBeat = pure ( Cell 1 Nothing )
  , _layerCode = "1"
  , _layerParsedCode = [ Cell 1 Nothing ]
  , _layerCellOffset = 0
  , _layerOffsetCode = "0"
  , _layerCellPrefix = 0
  , _layerSourcePrefix = []
  , _layerSourceType = pitch
  }
    where
      freq = pitchToFreq pitch
      source = linearTaper taperLength $ sineWave freq 0

-- | Progress a layer by the given number of samples
-- returning the resulting samples and the modified layer.
readChunk :: Int -> BPM -> Layer -> (Layer, [Sample])
readChunk bufferSize bpm layer@Layer{..}
  | prefixValue >= cellToTake =
    ( layer & layerSourcePrefix %~ (drop bufferSize)
            & layerCellPrefix   -~ cellToTake
    , Stream.take bufferSize $ _layerSourcePrefix `Stream.prepend` silence
    )
  | otherwise = ( remLayer, take bufferSize $ samples )
  where
    cellToTake  = numSamplesToCellValue bpm $ fromIntegral bufferSize
    prefixValue = layer^.layerCellPrefix

    (numPrefixSamples, remPrefixCell) = numSamplesForCellValue bpm prefixValue
    prefixSamples =
      Stream.take numPrefixSamples $ _layerSourcePrefix `Stream.prepend` silence
    (remLayer, newSamples) =
      getSamples bpm
                 ( layer & layerBeat . ix 0 %~ fmap ( + remPrefixCell ) )
                 ( bufferSize - numPrefixSamples )
                 ( drop numPrefixSamples _layerSourcePrefix )
    samples = prefixSamples ++ newSamples

-- | Pull the specified number of samples from a layer.
-- returns the samples and the modified layer.
getSamples :: BPM -> Layer -> Int -> [Sample] -> (Layer, [Sample])
getSamples bpm layer nsamps prevSource
  | nsamps <= wholeCellSamps = (newLayer, take nsamps source)
  | otherwise = _2 %~ ( take wholeCellSamps source ++ )
              $ getSamples bpm
                           ( layer & layerBeat . ix 0 %~ fmap ( + leftover ) )
                           ( nsamps - wholeCellSamps )
                           ( drop wholeCellSamps source )
  where
    ( c :> cells ) = layer^.layerBeat
    source = linearTaper taperLength $
      maybe ( dovetail ( pitchToFreq $ layer^.layerSourceType ) $ prevSource )
            id
            ( dovetail <$> ( pitchToFreq <$> c^.cellSource )
                       <*> Just prevSource
            )
    ( wholeCellSamps, leftover ) = numSamplesForCellValue bpm ( c^.cellValue )
    newCellPrefix = c^.cellValue
                  - numSamplesToCellValue bpm ( fromIntegral nsamps )
                  + leftover
    newLayer = layer & layerBeat         .~ cells
                     & layerCellPrefix   .~ newCellPrefix
                     & layerSourcePrefix .~ (drop nsamps source)

-- | Modify the layer at a specific index
modifyLayer :: JamState
            -> Int
            -> (Layer -> Layer)
            -> IO ()
modifyLayer st i modifier = signalSemaphore ( st^.jamStSemaphore ) $ do
  elapsedSamples <- readIORef ( st^.jamStElapsedSamples )
  tempo <- readIORef ( st^.jamStTempoRef )

  let elapsedCells = numSamplesToCellValue tempo
                   $ fromRational elapsedSamples

  modifyIORef' ( st^.jamStLayersRef ) $ \layers ->
    ( syncLayer elapsedCells ) <$> layers & ix i %~ modifier

-- | Apply the current contents of the beat code editor for a layer.
-- return true if the beat code is valid.
applyLayerBeatChange :: JamState
                     -> Int
                     -> IO Bool
applyLayerBeatChange st i = fmap isJust . runMaybeT $ do
  beatCode <- hoistMaybe $ getEditorContents
          <$> st ^? jamStLayerWidgets.ix i . layerWidgetCodeField

  cells <- hoistMaybe $ parseBeat beatCode

  liftIO $ modifyLayer st i ( ( layerBeat .~ Stream.cycle cells )
                            . ( layerCode .~ beatCode )
                            . ( layerParsedCode .~ cells )
                            )

-- | Apply the current contents of the offset field of a layer
-- returns true if beat code is valid.
applyLayerOffsetChange :: JamState
                       -> Int
                       -> IO Bool
applyLayerOffsetChange st i = fmap isJust . runMaybeT $ do
  offsetCode <- hoistMaybe $ getEditorContents
            <$> st ^? jamStLayerWidgets.ix i . layerWidgetOffsetField

  cellValue <- hoistMaybe $ parseOffset offsetCode

  liftIO $ modifyLayer st i ( ( layerCellOffset .~ cellValue )
                            . ( layerOffsetCode .~ offsetCode )
                            )

-- | Apply the contents of the source field to the layer
-- returning true if valid
applyLayerSourceChange :: JamState
                       -> Int
                       -> IO Bool
applyLayerSourceChange st i = fmap isJust . runMaybeT $ do
  noteStr <- hoistMaybe $ getEditorContents
         <$> st ^? jamStLayerWidgets.ix i . layerWidgetSourceField

  pitch <- hoistMaybe $ parsePitch noteStr

  liftIO . modifyIORef' ( st^.jamStLayersRef ) $ \layers ->
    let mbLayer = modifySource pitch <$> layers ^? ix i
     in maybe layers ( \x -> layers & ix i .~ x ) mbLayer

-- | Fast-forward a layer to the current time position
syncLayer :: CellValue -> Layer -> Layer
syncLayer elapsedCells layer
  | remainingElapsed <= 0 =
      layer & layerCellPrefix .~ abs remainingElapsed
  | otherwise =
      layer & layerBeat       .~ newCells
            & layerCellPrefix .~ cellPrefix
  where
    remainingElapsed       = elapsedCells - layer^.layerCellOffset
    cycleSize              = sum $ layer^.layerParsedCode^..traverse.cellValue
    elapsedCycles          = remainingElapsed / cycleSize
    wholeCycles            = fromIntegral $ truncate elapsedCycles
    cellsToDrop            = remainingElapsed - wholeCycles * cycleSize
    cellCycle              = Stream.cycle $ layer^.layerParsedCode
    (cellPrefix, newCells) = dropCells cellsToDrop cellCycle
    dropCells !dc ( c :> cs )
      | c^.cellValue >= dc = ( c^.cellValue - dc, cs )
      | otherwise = dropCells ( dc - c^.cellValue ) cs

-- | Change the sound source (Pitch) of the layer
modifySource :: Pitch -> Layer -> Layer
modifySource pitch layer = do
  let freq = pitchToFreq pitch
      wave = sineWave freq 0
      newSource = linearTaper taperLength wave

   in layer & layerSource     .~ newSource
            & layerSourceType .~ pitch

-- | Reset a layer to it's initial state
resetLayer :: Layer -> Layer
resetLayer layer =
  layer & layerBeat         .~ ( Stream.cycle $ layer^.layerParsedCode )
        & layerCellPrefix   .~ ( layer^.layerCellOffset )
        & layerSourcePrefix .~ []

hoistMaybe :: Applicative m => Maybe a -> MaybeT m a
hoistMaybe = MaybeT . pure
