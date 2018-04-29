module Models.Talk where

import           Control.Monad                    (liftM, mzero, void)
import           Data.Aeson
import qualified Data.ByteString.Char8            as C
import           Data.Text                        (Text)
import qualified Data.Text                        as T
import qualified Data.Text.IO                     as T
import           Data.Time                        (UTCTime)
import           Data.Time.Clock.POSIX            (posixSecondsToUTCTime)
import           Database.Beam
import           Database.Beam.Postgres
import qualified Database.Beam.Postgres.Full      as Pg
import qualified Database.PostgreSQL.Simple       as DB
import           Database.PostgreSQL.Simple.SqlQQ (sql)
import qualified Database.Redis                   as KV
import           GHC.Generics                     (Generic)
import           Network.HTTP.Conduit             (HttpException, Manager,
                                                   httpLbs, parseUrlThrow,
                                                   responseBody)
import           RIO                              hiding (id)
import           Text.HTML.DOM                    (parseLBS)
import           Text.XML.Cursor                  (fromDocument)
import           Types                            (AppM)

import           Config                           (Config (..))
import           Model
import qualified Models.RedisKeys                 as Keys
import           Models.Types                     (mkTalkUrl)
import           System.IO                        (print)
import           Web.TED                          (FileType (..), Subtitle (..),
                                                   toSub)
import           Web.TED.TalkPage                 (parseDescription, parseImage,
                                                   parseMediaPad,
                                                   parseMediaSlug,
                                                   parseTalkObject)


data TalkObj = TalkObj
  { id          :: Int
  , name        :: Text
  , slug        :: Text
  , filmedAt    :: UTCTime
  , publishedAt :: UTCTime
  , languages   :: [Language]
  } deriving (Generic, Show)

instance FromJSON TalkObj where
  parseJSON (Object v) = TalkObj
    <$> v .: "id"
    <*> v .: "name"
    <*> v .: "slug"
    <*> liftM posixSecondsToUTCTime (v .: "filmed")
    <*> liftM posixSecondsToUTCTime (v .: "published")
    <*> v .: "languages"
  parseJSON _          = mzero


getTalks :: Int -> AppM [Talk]
getTalks limit = do
  Config { dbConn } <- ask
  liftIO $ runBeamPostgres dbConn $ do
    runSelectReturningList $ select
      ( limit_ (fromIntegral limit)
      $ orderBy_ (\t -> desc_ (_talkId t))
      $ all_ (_talks talkDb)
      )

getTalk :: Int -> Text -> AppM (Maybe Talk)
getTalk tid url = do
  Config { kvConn } <- ask
  cached <- liftIO $ KV.runRedis kvConn $
    KV.get $ Keys.cache tid
  case cached of
    Right (Just _) -> getTalkById tid (Just url)
    Right Nothing  -> saveToDB url
    Left _         -> saveToDB url

getTalkById :: Int -> Maybe Text -> AppM (Maybe Talk)
getTalkById tid mUrl = do
  Config { dbConn } <- ask
  xs <- liftIO $ runBeamPostgres dbConn $ runSelectReturningOne $ select
    ( filter_ (\talk -> (_talkId talk ==. val_ tid))
    $ all_ (_talks talkDb)
    )
  case xs of
    Just talk -> return $ Just talk
    _         -> maybe (return Nothing) saveToDB mUrl

hush :: Either a b -> Maybe b
hush (Left _)  = Nothing
hush (Right v) = Just v

getTalkBySlug :: Text -> AppM (Maybe Talk)
getTalkBySlug slug = do
  Config { kvConn } <- ask
  mtid <- liftIO $ fmap (join . hush) <$> KV.runRedis kvConn $ KV.get $ Keys.slug slug
  case mtid of
    Just tid ->
      case readMaybe $ C.unpack tid of
        Just tid' -> getTalk tid' url
        Nothing   -> pure Nothing
    Nothing  ->
      saveToDB url
  where
    url = mkTalkUrl slug

saveToDB :: Text -> AppM (Maybe Talk)
saveToDB url = do
  config@Config{..} <- ask
  mTalk <- liftIO $ fetchTalk httpManager url
  case mTalk of
    Just talk -> do
      void $ liftIO $ KV.runRedis kvConn $ KV.multiExec $ do
          void $ KV.setex (Keys.cache $ _talkId talk) (3600*24) ""
          KV.set (Keys.slug $ _talkSlug talk) (C.pack $ show $ _talkId talk)

      liftIO $ runBeamPostgres dbConn $ runInsert $
        Pg.insert (_talks talkDb) (insertValues [ talk ]) $
          Pg.onConflict (Pg.conflictingFields primaryKey) $
            Pg.onConflictUpdateInstead $
              \t -> ( _talkLanguages t
                    , _talkMediaPad t
                    )

      saveTranscriptIfNotAlready talk
      return $ Just talk
    Nothing -> return Nothing

saveTranscriptIfNotAlready :: Talk -> AppM ()
saveTranscriptIfNotAlready Talk {..} = do
  Config { dbConn } <- ask
  xs <- liftIO $ runBeamPostgres dbConn $ runSelectReturningOne $ select
    ( filter_ (\transcript -> (_transcriptTalk transcript ==. val_ (TalkId _talkId)))
    $ all_ (_transcripts talkDb)
    )
  case xs of
    Just _ -> pure ()
    Nothing   -> do
      path <- liftIO $ toSub $
        Subtitle _talkId _talkSlug ["en"] _talkMediaSlug _talkMediaPad TXT
      case path of
        Just path' -> do
          transcript <- liftIO $ T.drop 2 <$> T.readFile path'
          -- runBeamPostgres conn $ runInsert $
          --   Pg.insert (_transcripts talkDb)
          --     ( insertExpressions
          --       [ Transcript (val_ $ TalkId _talkId) $ toTsVector (Just english) (val_ transcript) ]
          --     ) $
          --     Pg.onConflict Pg.anyConflict Pg.onConflictDoNothing
          void $ liftIO $ DB.execute dbConn [sql|
              INSERT INTO transcripts (id, en_tsvector)
              VALUES (?, to_tsvector('english', ? || ?))
          |] (_talkId, _talkName, transcript)
        Nothing -> return ()

fetchTalk :: Manager -> Text -> IO (Maybe Talk)
fetchTalk manager url = do
  handle (\(_::HttpException) -> return Nothing) $ do
    req <- parseUrlThrow $ T.unpack url
    res <- httpLbs req manager
    let
      body = responseBody res
      cursor = fromDocument $ parseLBS body
      desc = parseDescription cursor
      img = parseImage cursor
      mdSlug = parseMediaSlug body
      mdPad = parseMediaPad body
      core = parseTalkObject body
    case decode core of
      Just TalkObj{..} -> do
        return $ Just Talk
          { _talkId = id
          , _talkName = name
          , _talkSlug = slug
          , _talkFilmed = filmedAt
          , _talkPublished = publishedAt
          , _talkDescription = desc
          , _talkImage = img
          , _talkLanguages = languages
          , _talkMediaSlug = mdSlug
          , _talkMediaPad = mdPad
          }
      _      -> do
        print $ "<fetchTalk>: parse error " <> T.unpack url
        pure Nothing
