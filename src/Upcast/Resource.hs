{-# LANGUAGE OverloadedStrings
           , RecordWildCards
           , NamedFieldPuns
           , ScopedTypeVariables
           , DeriveFunctor
           , ExistentialQuantification
           , FlexibleContexts
           , TypeFamilies
           , LambdaCase
           #-}

module Upcast.Resource where

import Prelude hiding (sequence)

import Control.Applicative
import Control.Monad.Reader hiding (sequence, forM)
import Control.Monad.Trans.Resource (ResourceT, liftResourceT, runResourceT)
import Control.Monad.Trans.Resource (MonadBaseControl)
import Control.Monad.Free
import qualified Control.Exception.Lifted as E
import Control.Concurrent (threadDelay)
import System.IO

import Data.Maybe (listToMaybe)
import Data.Monoid
import Data.Traversable
import qualified Data.List as L
import qualified Data.HashMap.Strict as H
import Data.HashMap.Strict (HashMap)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Aeson
import qualified Data.Aeson.Encode.Pretty as A
import qualified Data.Aeson.Types as A
import qualified Data.Vector as V
import System.FilePath.Posix (splitFileName)

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.ByteString.Lazy (toStrict)

import System.IO (stderr)
import qualified Network.HTTP.Conduit as HTTP
import qualified Aws
import Aws.Core
import Aws.Query (QueryAPIConfiguration(..), castValue)
import Aws.Canonical (canonicalSigData)
import qualified Aws.Ec2 as EC2
import qualified Aws.Route53 as R53

import Upcast.Types
import Upcast.Command (fgconsume_, Command(..), Local(..))

import Upcast.TermSubstitution

import Upcast.Resource.Types
import Upcast.Resource.Ec2

-- | ReaderT context ResourcePlan evaluates in.
data EvalContext = EvalContext
               { mgr :: HTTP.Manager
               , awsConf :: Aws.Configuration
               , qapi :: QueryAPIConfiguration NormalQuery
               , route53 :: R53.Route53Configuration NormalQuery
               }

rqBody :: (MonadIO io, SignQuery r) => r -> ServiceConfiguration r q -> io Text
rqBody tx conf = do
    sig <- liftIO $ canonicalSigData
    let s = signQuery tx conf sig
    let Just body = sqBody s
    return $ bodyText body
  where
    bodyText :: HTTP.RequestBody -> Text
    bodyText (HTTP.RequestBodyBS bs) = T.decodeUtf8 bs
    bodyText (HTTP.RequestBodyLBS lbs) = T.decodeUtf8 $ toStrict lbs

substituteTX :: SubStore -> TX -> EvalContext -> ResourceT IO (Sub, SubStore, Value)
substituteTX state (TX tx) EvalContext{..} = do
    key <- rqBody tx qapi
    -- liftIO $ T.putStrLn key
    liftIO $ substitute state key (runResourceT $ Aws.pureAws awsConf qapi mgr tx)

substitute_ :: SubStore -> Text -> IO any -> ResourceT IO (Sub, SubStore, Value)
substitute_ state key action = liftIO $ do
    T.putStrLn key
    substitute state key (action >> return Null)

evalPlan :: SubStore -> ResourcePlan a -> ReaderT EvalContext (ResourceT IO) a
evalPlan state (Free (AWSR (TXR tx keyPath) next)) = do
    sub@(t, state', val) <- ask >>= liftResourceT . substituteTX state tx
    let result = acast keyPath val :: Text
    -- liftIO $ print (t, val, result)
    evalPlan state' $ next result
evalPlan state (Free (AWS tx next)) = do
    sub@(t, state', val) <- ask >>= liftResourceT . substituteTX state tx
    -- liftIO $ print (t, val)
    evalPlan state' next
evalPlan state (Free (AWSV (TX tx) next)) = do
    EvalContext{..} <- ask
    result <- liftResourceT $ Aws.pureAws awsConf qapi mgr tx
    evalPlan state $ next result
evalPlan state (Free (Wait (TX tx) next)) = do
    EvalContext{..} <- ask
    desc <- txshow tx
    r <- liftIO $ runResourceT $ retry desc (Aws.pureAws awsConf qapi mgr tx) awsTest
    -- liftIO $ print r
    evalPlan state next
evalPlan state (Free (AWS53CRR crr next)) = do
    EvalContext{..} <- ask
    txb <- liftIO $ rqBody crr route53
    (_, state', val) <- liftResourceT $ substitute_ state txb (runResourceT $
                      retry "ChangeResourceRecordSets" (Aws.pureAws awsConf route53 mgr crr) r53Test)
    evalPlan state' $ next "ok"
evalPlan state (Pure r) = return r


txshow :: (MonadIO io, ServiceConfiguration r ~ QueryAPIConfiguration, Transaction r Value)
          => r
          -> ReaderT EvalContext io Text
txshow tx = do
    EvalContext{qapi} <- ask
    rqBody tx qapi

debugPlan :: SubStore -> ResourcePlan a -> ReaderT EvalContext IO a
debugPlan state (Free (AWSR (TXR (TX tx) keyPath) next)) = do
    txshow tx >>= liftIO . T.putStrLn
    debugPlan state $ next "dbg-00000"
debugPlan state (Free (AWS (TX tx) next)) = do
    txshow tx >>= liftIO . T.putStrLn
    debugPlan state next
debugPlan state (Free (AWSV (TX tx) next)) = do
    txshow tx >>= liftIO . T.putStrLn
    debugPlan state $ next $ Array V.empty
debugPlan state (Free (Wait (TX tx) next)) = do
    liftIO (putStrLn "-- wait")
    debugPlan state next
debugPlan state (Free (AWS53CRR crr next)) = do
    EvalContext{..} <- ask
    txb <- liftIO $ rqBody crr route53
    liftIO $ print (crr, txb)
    debugPlan state $ next "dbg-ok"
debugPlan state (Pure r) = return r


retry :: forall exc ret m. (E.Exception exc, MonadIO m, MonadBaseControl IO m)
         => Text
         -> m ret
         -> (Either exc ret -> Either String ret)
         -> m ret
retry desc action test = loop
  where
    loop = do
      result <- catchAll action
      case (test result) of
        Left reason -> warn reason >> loop
        Right v -> return v

    warn val = liftIO $ do
      T.hPutStrLn stderr (T.concat ["retrying <", desc, "> after 1: ", T.pack val])
      threadDelay 1000000

    catchAll :: m ret -> m (Either exc ret)
    catchAll = E.handle (return . Left) . fmap Right

awsTest :: Either E.SomeException Value -> Either String Value
awsTest (Left x) = Left $ show x
awsTest (Right Null) = Left $ show Null
awsTest (Right r) = Right r

r53Test :: Either R53.Route53Error a -> Either String a
r53Test (Left x) = Left $ show x
r53Test (Right r) = Right r


findRegions :: [Text] -> Value -> [Text]
findRegions acc (Object h) = mappend nacc $ join (findRegions [] <$> (fmap snd $ H.toList h))
  where
    nacc = maybe [] (\case String x -> [x]; _ -> []) $ H.lookup "region" h
findRegions acc (Array v) = mappend acc $ join (findRegions [] <$> V.toList v)
findRegions acc _ = acc

-- | read files mentioned in userData for each instance
preReadUserData :: Value -> IO [(Text, HashMap Text Text)]
preReadUserData info =
    fmap mconcat $ forM (alistFromObject "machines" info) $ \inst -> do
        let (name, dataA) = parse inst $ \(name, Object obj) -> do
              Object ec2 <- obj .: "ec2"
              dataA :: HashMap Text Text <- ec2 .: "userData"
              return (name, dataA)
        readA <- sequence $ fmap (T.readFile . T.unpack) dataA
        return [(name, readA)]

-- | pre-calculate EC2.ImportKeyPair values while we can do IO
prepareKeyPairs :: Value -> IO [(Text, EC2.ImportKeyPair)]
prepareKeyPairs info =
    fmap mconcat $ forM (mcast "resources.ec2KeyPairs" info :: [Value]) $ \keypair -> do
        let (kName, kPK) = parse keypair $ \(Object obj) -> do
                              kName <- obj .: "name" :: A.Parser Text
                              kPK <- obj .: "privateKeyFile" :: A.Parser Text
                              return $ (kName, kPK)
        pubkey <- fgconsume_ $ Cmd Local (mconcat ["ssh-keygen -f ", T.unpack kPK, " -y"]) "ssh-keygen"
        return [(kPK, EC2.ImportKeyPair kName $ T.decodeUtf8 $ Base64.encode pubkey)]

debugEvalResources :: DeployContext -> Value -> IO [Machine]
debugEvalResources ctx@DeployContext{..} info = do
    let region = "us-east-1"
    let (keypair, keypairs) = (Nothing, [])

    userDataA <- preReadUserData info

    instances <- do
      awsConf <- liftIO $ Aws.dbgConfiguration
      let context = EvalContext undefined awsConf (QueryAPIConfiguration $ T.encodeUtf8 region) R53.route53
          action = debugPlan emptyStore (ec2plan name (snd <$> keypairs) info userDataA)
          in runReaderT action context

    -- mapM_ LBS.putStrLn $ fmap A.encodePretty instances

    return $ fmap (toMachine keypair) instances
  where
    name = T.pack $ snd $ splitFileName $ T.unpack expressionFile

    toMachine k (h, info) = Machine h
                                    (cast "instancesSet.ipAddress" :: Text)
                                    (cast "instancesSet.privateIpAddress" :: Text)
                                    (cast "instancesSet.instanceId" :: Text)
                                    k
      where
        cast :: FromJSON a => Text -> a
        cast = (`acast` info)

evalResources :: DeployContext -> Value -> IO [Machine]
evalResources ctx@DeployContext{..} info = do
    region <- let regions = L.nub $ findRegions [] info
                  in case regions of
                       reg:[] -> return reg
                       _ -> error $ mconcat [ "can only operate with expressions that "
                                            , "do not span multiple EC2 regions, given: "
                                            , show regions
                                            ]
    store <- loadSubStore stateFile

    keypairs <- prepareKeyPairs info
    let keypair = fst <$> listToMaybe keypairs

    userDataA <- preReadUserData info

    instances <- HTTP.withManager $ \mgr -> do
      awsConf <- liftIO $ Aws.baseConfiguration
      let context = EvalContext mgr awsConf (QueryAPIConfiguration $ T.encodeUtf8 region) R53.route53
          action = evalPlan store (ec2plan name (snd <$> keypairs) info userDataA)
          in runReaderT action context

    -- mapM_ LBS.putStrLn $ fmap A.encodePretty instances

    return $ fmap (toMachine keypair) instances
  where
    name = T.pack $ snd $ splitFileName $ T.unpack expressionFile

    toMachine k (h, info) = Machine h
                                    (cast "instancesSet.ipAddress" :: Text)
                                    (cast "instancesSet.privateIpAddress" :: Text)
                                    (cast "instancesSet.instanceId" :: Text)
                                    k
      where
        cast :: FromJSON a => Text -> a
        cast = (`acast` info)
