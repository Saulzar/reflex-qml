{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecursiveDo #-}
module Main where

import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import Control.Monad.Fix
import Control.Monad.IO.Class
import Control.Monad.Trans
import Graphics.QML.Engine
import Prelude
import Reflex
import Reflex.QML.Internal.AppHost
import Reflex.QML.Internal.Object
import Reflex.QML.Internal.Run

import qualified Data.Text as Text
import qualified Reflex.QML.Prop as Prop

data TodoItem = TodoItem
  { description :: Text.Text
  , completed :: Bool
  , editing :: Bool
  }

engineConfig :: EngineConfig
engineConfig = defaultEngineConfig
  { initialDocument = fileDocument "examples/todomvc/Main.qml"
  }

startEventLoop :: IO ()
startEventLoop = do
  l <- newEmptyMVar
  void . forkIO $
    catch (runEventLoop . liftIO $ putMVar l () >> forever (threadDelay maxBound)) $ \e ->
      (e :: EventLoopException) `seq` putMVar l ()
  takeMVar l

makeItem :: MonadAppHost t m => Text.Text -> ObjectT m (Event t (), Dynamic t TodoItem)
makeItem desc = mdo
  descriptionD <- Prop.mutableHold "description" desc
  completedD <- Prop.mutableHold "completed" False
  editingD <- Prop.mutableHold "editing" False
  removedE <- void <$> Prop.method "remove" (constDyn ((), ()))
  todoD <- $(qDyn
   [| TodoItem
      $(unqDyn [| descriptionD |])
      $(unqDyn [| editingD |])
      $(unqDyn [| completedD |])
   |])
  return (removedE, todoD)

data Removable t a = Removable
  { removableAlive :: Dynamic t Bool
  , removableValue :: a
  }

list :: forall t m a. (Reflex t, MonadHold t m, MonadSample t m, MonadFix m)
     => [Removable t a] -> m (Dynamic t [Removable t a])
list items = mdo
  let
    removedItems :: Event t [Removable t a]
    removedItems = pushAlways (const $ filterM isAlive =<< currentItems) removedE

    isAlive :: Removable t a -> PushM t Bool
    isAlive = sample . current . removableAlive

    currentItems :: PushM t [Removable t a]
    currentItems = sample $ current itemsDyn

  itemsDyn <- holdDyn items removedItems
  removedE <- fmap (switch . current) $
    mapDyn (leftmost . map (void . updated . removableAlive)) itemsDyn
  pure itemsDyn

data TodoFilter = FilterAll | FilterActive | FilterCompleted

main :: IO ()
main = do
  startEventLoop
  requireEventLoop $ hostQmlApp engineConfig $ Prop.namespace "app" $ mdo
    newItem <- Prop.methodVoid "newItem" . constDyn $ \x -> (x,())
    todoItems <- lift . fmap joinDyn $ holdAppHost (return $ constDyn []) $
     ffor newItem $ \x -> do
      (obj, (removedE, todoD)) <- runObjectT $ makeItem x
      alive <- holdDyn True $ False <$ removedE
      oldItems <- sample $ current todoItems
      list (Removable alive (obj, todoD) : oldItems)
    Prop.readonly "todos" =<< mapDyn (reverse . map (fst . removableValue)) todoItems
    todoFilter <- Prop.namespace "filter" $ do
      completedE <- Prop.methodVoid "completed" $ constDyn ((),())
      allE       <- Prop.methodVoid "all" $ constDyn ((),())
      activeE    <- Prop.methodVoid "active" $ constDyn ((),())
      pure $ mergeWith (const . const $ FilterAll)
       [ FilterCompleted <$ completedE
       , FilterActive    <$ activeE
       , FilterAll       <$ allE
       ]
    return ()
