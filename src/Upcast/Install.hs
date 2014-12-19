{-# LANGUAGE TemplateHaskell, OverloadedStrings, RecordWildCards, NamedFieldPuns #-}

module Upcast.Install (
  installMachines
, install
) where

import Control.Exception.Base (SomeException, try)

import qualified Data.Map as Map
import qualified Data.Text as T
import Data.Text (Text(..))

import Control.Concurrent.Async
import System.FilePath.Posix
import System.Posix.Files (readSymbolicLink)
import System.Posix.Env (getEnv)
import Data.ByteString.Char8 (split)

import Upcast.Monad
import Upcast.IO
import Upcast.Types
import Upcast.Command
import Upcast.DeployCommands
import Upcast.Environment

data FgCommands =
  FgCommands { fgrun' :: Command Local -> IO ()
             , fgssh :: Command Remote -> IO ()
             }

fgCommands fgrun = FgCommands{..}
  where
    fgrun' = expect ExitSuccess "install step failed" . fgrun
    fgssh = fgrun' . ssh

installMachines :: DeliveryMode -> (Hostname -> IO StorePath) -> [Machine] -> IO (Either [Install] ())
installMachines dm resolveClosure machines = do
    installs <- mapM installP machines
    results <- mapConcurrently (try . go fgc dm) installs :: IO [Either SomeException ()]
    case [i{i_paths=["<stripped>"]} | (e, i) <- zip results installs, isLeft e] of
        [] -> return $ Right ()
        failures -> do
          warn ["installs failed: ", show failures]
          return $ Left failures
  where
    fgc = case machines of
              [x] -> fgCommands fgrunDirect
              _ -> fgCommands fgrunProxy

    isLeft :: Either a b -> Bool
    isLeft (Left _) = True
    isLeft _ = False

    installP :: Machine -> IO Install
    installP Machine{..} = do
        nixSSHClosureCache <- getEnv "UPCAST_SSH_CLOSURE_CACHE"
        i_closure <- resolveClosure m_hostname
        i_paths <- (fmap (split '\n') . fgconsume_ . nixClosure) $ i_closure
        return Install{..}
      where
        i_remote = Remote (T.unpack <$> m_keyFile) ("root@" ++ T.unpack m_publicIp)
        i_profile = nixSystemProfile
  
install :: (Command Local -> IO ExitCode) -> InstallCli -> IO ()
install fgrun args@InstallCli{..} = do
  let i_closure = ic_closure
      i_remote = Remote Nothing $ "root@" ++ ic_target
      i_paths = []
      i_profile = maybe nixSystemProfile id ic_profile
  go (fgCommands fgrun) (toDelivery ic_pullFrom) Install{..}

go :: FgCommands -> DeliveryMode -> Install -> IO ()
go FgCommands{..} dm install@Install{i_paths} = do
  nixSSHClosureCache <- getEnv "UPCAST_SSH_CLOSURE_CACHE"
  case nixSSHClosureCache of
      Just cache -> do
        fgssh $ sshPrepKnownHost cache install
        unless (null i_paths) $ fgssh . nixTrySubstitutes cache $ install
      _ -> return ()

  case dm of
      Push -> fgrun' . nixCopyClosureToI $ install
      Pull from -> fgssh . nixCopyClosureFrom from $ install

  fgssh . nixSetProfile $ install
  when (i_profile install == nixSystemProfile) $ do
    fgssh . nixSwitchToConfiguration $ install

