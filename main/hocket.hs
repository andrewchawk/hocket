{-# LANGUAGE OverloadedStrings #-}

import           Control.Applicative ((<*>), pure)
import           Control.Concurrent (forkIO, threadDelay, MVar, newEmptyMVar, takeMVar, tryPutMVar, readMVar)
import           Control.Monad (join, void, replicateM_, when)
import           Control.Monad.Error (runErrorT)
import           Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Char8 as CS
import           Data.ConfigFile
import           Data.Default
import           Data.Foldable (traverse_, for_, for_)
import           Data.Functor ((<$>))
import           Data.List (sortBy, sortBy, (\\))
import qualified Data.Map as M
import           Data.Maybe (fromMaybe)
import           Data.Ord (comparing)
import qualified Data.Text as T
import           Data.Text.Encoding (encodeUtf8)
import           Data.Traversable (Traversable, for)
import           Graphics.Vty
import           Graphics.Vty.Widgets.All
import           Numeric.Natural
import           System.Exit (exitSuccess)
import           System.Posix.Env.ByteString (getArgs)
import           System.Process
import           Text.Printf (printf)

import           Parsing
import           Pocket
import           Printing
import           Types
import           Util

forkIO_ :: IO () -> IO ()
forkIO_ = void . forkIO

main :: IO ()
main = do
  creds <- readFromConfig "hocket.cfg"
  args <- getArgs
  let (dispatch,rest) = (head args, tail args)
  runHocket (creds,def) $ case dispatch of
    "get" -> liftIO . newestFirst =<< performGet (read . CS.unpack . head $ rest)
    "add" -> traverse_ addItem rest
    "archive" -> for_ rest $ \x -> do
      res <- archive x
      liftIO . putStrLn . show $ res
      mapM_ archive rest
    "gui" -> liftIO . vty creds $ []
    _ -> fail "Invalid args."

performGet :: Maybe (Natural,Natural) -> Hocket (PocketCredentials, PocketAPIUrls) [PocketItem]
performGet maybeOffsetCount = do
  retrieved <- retrieveList maybeOffsetCount
  return . sortBy (flip $ comparing timeAdded)
         . M.elems
         . fromMaybe M.empty
         . parseItems $ retrieved

readFromConfig :: FilePath -> IO PocketCredentials
readFromConfig path = do
  Right (token,key,shCmd) <- runErrorT $ do
    cp <- join $ liftIO $ readfile emptyCP path
    accessToken <- get cp "Credentials" "access_token"
    consumerKey <- get cp "Credentials" "consumer_key"
    cmd <- get cp "Launch" "launch_cmd"
    return ( AccessToken . CS.pack $ accessToken
           , ConsumerKey . CS.pack $ consumerKey
           , cmd)
  return $ PocketCredentials key token shCmd

browseItem :: String -> T.Text -> IO ()
browseItem shellCmd url = do
  let spec = shell $ printf shellCmd (T.unpack url)
      spec' = spec {std_out = CreatePipe, std_err = CreatePipe}
  void $ createProcess spec'

addLstItem :: Widget (List PocketItem FormattedText) -> PocketItem -> IO ()
addLstItem lst itm = addToList lst itm =<< (plainText . bestTitle $ itm)

data HocketGUI = HocketGUI { unreadLst :: Widget (List PocketItem FormattedText)
                           , toArchiveLst :: Widget (List PocketItem FormattedText)
                           , helpBar :: Widget FormattedText
                           , statusBar :: Widget FormattedText
                           , guiCreds :: PocketCredentials
                           , launchCommand :: String
                           , mainFocusGroup :: Widget FocusGroup
                           , titleText :: Widget FormattedText
                           , asyncAction :: MVar (IO ())
                           }

startExecuter :: MVar (IO ()) -> IO ()
startExecuter m = forkIO_ loop
  where loop = do act <- readMVar m; act >> void (takeMVar m) >> loop

tryAsync :: HocketGUI -> IO () -> IO ()
tryAsync gui = void . tryPutMVar (asyncAction gui)

insertPocketItems :: Traversable f =>
                     Widget (List PocketItem FormattedText)
                     -> f PocketItem -> IO ()
insertPocketItems lst = traverse_ (addLstItem lst)

sortList :: Widget (List PocketItem FormattedText) -> IO ()
sortList lst = do
  sel <- getSelected lst
  pis <- sortBy (flip $ comparing timeAdded) <$> extractAndClear lst
  insertPocketItems lst pis
  for_ sel $ \(pos, _) -> setSelected lst pos

getAllItems :: Widget (List a b) -> IO [a]
getAllItems lst = do
  n <- getListSize lst
  for [0..(n-1)] $ \i -> do
    Just (itm, _) <- getListItem lst i
    return itm

extractAndClear :: Widget (List a b) -> IO [a]
extractAndClear lst = do
  itms <- getAllItems lst
  clearList lst
  return itms

updateStatusBar :: HocketGUI -> T.Text -> IO ()
updateStatusBar gui txt = schedule $ setText (statusBar gui) txt

retrieveNewItems :: HocketGUI -> IO ()
retrieveNewItems gui = do
  tryAsync gui $ do
    updateStatusBar gui "Updating "
    oldPIs <- (++) <$> (getAllItems $ unreadLst gui) <*> (getAllItems $ toArchiveLst gui)
    eitherErrorPIs <-
      tryHttpException $ runHocket (guiCreds gui, def) $ performGet Nothing
    case eitherErrorPIs of
      Right pis -> schedule $ do
        insertPocketItems (unreadLst gui) $ pis \\ oldPIs
        sortList (unreadLst gui)
        updateStatusBar gui ""
      Left _ -> updateStatusBar gui "Updating failed"

removeItemFromLst :: Eq a => Widget (List a b) -> a -> IO ()
removeItemFromLst lst itm = do
  maybePos <- listFindFirst lst itm
  traverse_ (removeFromList lst) maybePos

executeArchiveAction :: HocketGUI -> IO ()
executeArchiveAction gui = do
  tryAsync gui $ do
    updateStatusBar gui "Archiving "
    let archiveLst = toArchiveLst gui
    itms <- getAllItems archiveLst
    res <- performArchive itms archiveLst
    updateStatusBar gui
             . either (const "Archieving failed") (const "")
             $ res
  where performArchive itms archiveLst =
          tryHttpException $ runHocket (guiCreds gui, def) $ do
            for_ itms $ \itm -> do
              successful <- archive . encodeUtf8 . itemId $ itm
              liftIO . when successful . schedule $
                removeItemFromLst archiveLst itm


keepCurrent :: Attr
keepCurrent = Attr KeepCurrent KeepCurrent KeepCurrent

boldBlackOnOrange :: Attr
boldBlackOnOrange = realBlack `on` (Color240 147) `mergeAttr` style bold
  where realBlack = rgb_color (0::Int) 0 0

createGUI :: PocketCredentials -> IO (HocketGUI, Collection)
createGUI cred = do
   gui <- HocketGUI <$> (newList keepCurrent 1)
                    <*> (newList keepCurrent 1)
                    <*> (plainText . T.intercalate " | " $ [ "q:Quit"
                                                           , "d:Shift item"
                                                           , "D:Shift all"
                                                           , "u:Update"
                                                           , "A:Archive pending"
                                                           , "SPC: Launch"
                                                           , "Enter:Launch & Shift"
                                                           ])
                   <*> plainText ""
                   <*> pure cred
                   <*> pure (credShellCmd cred)
                   <*> newFocusGroup
                   <*> plainText "Hocket"
                   <*> newEmptyMVar

   startExecuter (asyncAction gui)
   bottomBar <- ((pure $ helpBar gui) <++> hFill ' ' 1 <++> (pure $ statusBar gui))
   topBar <- ((pure $ titleText gui) <++> hFill ' ' 1)

   setNormalAttribute (bottomBar) $ Attr KeepCurrent KeepCurrent (SetTo black)
   setNormalAttribute (topBar) $ Attr KeepCurrent KeepCurrent (SetTo black)
   setNormalAttribute (statusBar gui) $ Attr (SetTo bold) KeepCurrent KeepCurrent

   setFocusAttribute (unreadLst gui) boldBlackOnOrange
   setFocusAttribute (toArchiveLst gui) boldBlackOnOrange
   for_ [unreadLst,toArchiveLst] $ \selector ->
     setNormalAttribute (selector gui) $ Attr KeepCurrent (SetTo white) KeepCurrent
   for_ [helpBar, statusBar] $ \selector ->
     setNormalAttribute (selector gui) $ Attr KeepCurrent (SetTo white) KeepCurrent

   ui <- centered =<< pure topBar
                 <--> (pure $ unreadLst gui)
                 <--> hBorder
                 <--> (vFixed 10 (toArchiveLst gui))
                 <--> pure bottomBar

   let fg = mainFocusGroup gui
   void $ addToFocusGroup fg (unreadLst gui)
   void $ addToFocusGroup fg (toArchiveLst gui)

   fg `onKeyPressed` \_ k _ -> case k of
     (KASCII 'q') -> exitSuccess
     (KASCII 'u') -> retrieveNewItems gui >> return True
     (KASCII 'A') -> executeArchiveAction gui >> return True
     _ -> return False
   c <- newCollection
   void $ addToCollection c ui fg
   return (gui,c)

vty :: PocketCredentials -> [PocketItem] -> IO ()
vty cred  pis = do
  (gui,c) <- createGUI cred
  insertPocketItems (unreadLst gui) pis

  for_ [unreadLst gui, toArchiveLst gui] $ \x -> do
    x `onItemActivated` (lstItemActivatedHandler gui x)
    x `onKeyPressed` lstKeyPressedHandler gui

  (unreadLst gui) `onKeyPressed` \this key _ -> case key of
    (KASCII 'd') -> shiftSelected this (toArchiveLst gui) >> return True
    (KASCII 'D') -> do
      insertPocketItems (toArchiveLst gui) =<< extractAndClear this
      focusNext (mainFocusGroup gui)
      return True
    _ -> return False

  (toArchiveLst gui) `onKeyPressed` \this key _ -> case key of
    (KASCII 'd') -> shiftSelected this (unreadLst gui) >> return True
    (KASCII 'D') -> do
      insertPocketItems (unreadLst gui) =<< extractAndClear this
      focusNext (mainFocusGroup gui)
      return True

    _ -> return False

  retrieveNewItems gui
  runUi c defaultContext

lstKeyPressedHandler :: HocketGUI
                     -> Widget (List PocketItem FormattedText)
                     -> Key
                     -> t
                     -> IO Bool
lstKeyPressedHandler gui this key _ = case key of
  (KASCII 'j') -> scrollDown this >> return True
  (KASCII 'k') -> scrollUp this >> return True
  (KASCII 'J') -> replicateM_ 3 (scrollDown this) >> return True
  (KASCII 'K') -> replicateM_ 3 (scrollUp this) >> return True
  (KASCII 's') -> sortList this >> return True
  (KASCII 'g') -> scrollToBeginning this >> return True
  (KASCII 'G') -> scrollToEnd this >> return True
  (KASCII ' ') -> do
    forkIO_ $ do
      maybeSel <- getSelected this
      traverse_ (browseItem (launchCommand gui) . givenUrl . fst . snd) maybeSel
    return True
  _ -> return False

lstItemActivatedHandler :: HocketGUI
                        -> Widget (List PocketItem FormattedText)
                        -> ActivateItemEvent PocketItem t
                        -> IO ()
lstItemActivatedHandler gui src (ActivateItemEvent _ v _) = do
  shiftSelected src (toArchiveLst gui)
  browseItem (launchCommand gui) . givenUrl $ v

shiftSelected :: Widget (List PocketItem FormattedText)
         -> Widget (List PocketItem FormattedText)
         -> IO ()
shiftSelected this target = do
  sel <- getSelected this
  for_ sel $ \(pos, (val, _)) -> do
    void $ removeFromList this pos
    addLstItem target val
  sortList target


{--------------------
import Data.Aeson.Lens
import Control.Lens

selected cts = fmap (\x -> x-1) $ cts ^? key "windows" . _Array . _head . key "selected" . _Integral

getTabUrl cts i = cts ^? key "windows" . _Array . _head . key "tabs" . nth i . key "entries" . _Array . _last . key "url" . _String

getSelectedTabUrl cts = selected cts >>= getTabUrl cts

run it:
-- fmap getSelectedTabUrl (readFile "/home/markus/.mozilla/firefox/n5kzdn7q.default/sessionstore.js")
--------------------}
