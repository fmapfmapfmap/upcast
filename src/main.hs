{-# LANGUAGE QuasiQuotes, TemplateHaskell, OverloadedStrings, RecordWildCards #-}

module Main where

import System.FilePath.Posix ((</>))
import Data.Maybe (fromJust)
import qualified Data.Text as T
import Data.Text (Text(..))

import Upcast.Interpolate (n)

import Upcast.State
import Upcast.Nix
import Upcast.PhysicalSpec
import Upcast.Command
import Upcast.Temp

nixops = "/tank/proger/dev/nix/decl/nixops/nixops/../nix"
nixPath = "sources"
stateFile = "deployments.nixops" :: Text
deploymentName = "staging" :: Text
closuresPath = "/tmp/machines/1"
key = "id_rsa.tmp"

nixBaseOptions = [n|
                 -I #{nixPath}
                 -I nixops=#{nixops} 
                 --option use-binary-cache true
                 --option binary-caches http://hydra.nixos.org
                 --option use-ssh-substituter true
                 --option ssh-substituter-hosts me@node1.example.com
                 --show-trace
                 |]

sshAgent socket = Cmd Local [n|ssh-agent -a #{socket}|]
sshAddKey socket key = Cmd Local [n|echo '#{key}' | env SSH_AUTH_SOCK=#{socket} SSH_ASKPASS=/usr/bin/true ssh-add -|]
sshListKeys socket = Cmd Local [n|env SSH_AUTH_SOCK=#{socket} ssh-add -l|]

nixCopyClosureTo (Remote key host) path =
    Cmd Local [n|env NIX_SSHOPTS="-i #{key}" nix-copy-closure --to root@#{host} #{path} --gzip|]

nixCopyClosureToFast controlPath (Remote key host) path =
    Cmd Local [n|env NIX_SSHOPTS="-i #{key} -S #{controlPath}" nix-copy-closure --to root@#{host} #{path} --gzip|]

nixDeploymentInfo exprs uuid = Cmd Local [n|
                     nix-instantiate #{nixBaseOptions}
                     --arg networkExprs '#{listToNix exprs}'
                     --arg args {}
                     --argstr uuid #{uuid}
                     '<nixops/eval-deployment.nix>'
                     --eval-only --strict --read-write-mode
                     --arg checkConfigurationOptions false
                     -A info
                     |]

nixBuildMachines exprs uuid names outputPath = Cmd Local [n|
                   nix-build #{nixBaseOptions}
                   --arg networkExprs '#{listToNix exprs}'
                   --arg args {}
                   --argstr uuid #{uuid}
                   --arg names '#{listToNix names}'
                   '<nixops/eval-deployment.nix>'
                   -A machines
                   -o #{outputPath}
                   |]

nixSetProfile remote closure = Cmd remote [n|
                                  nix-env -p /nix/var/nix/profiles/system --set "#{closure}"
                                  |]

nixSwitchToConfiguration remote = Cmd remote [n|
                                  env NIXOS_NO_SYNC=1 /nix/var/nix/profiles/system/bin/switch-to-configuration switch
                                  |]

-- nixTrySubstitutes remote closure =
               -- closure = subprocess_check_output(["nix-store", "-qR", path]).splitlines()
               -- self.run_command("nix-store -j 4 -r --ignore-unknown " + ' '.join(closure), check=False)


attr Resource{..} = fromJust . flip lookup resourceAList
dattr Deployment{..} = fromJust . flip lookup deploymentAList

data State = State Deployment [Resource] [String] [Resource]
           deriving (Show)

state = do
  (deployment, res) <- runState stateFile $ do
    d <- onlyDeployment deploymentName >>= deploymentAttrs
    rs <- resources d >>= sequence . fmap resourceAttrs
    return (d, rs)

  let Right exprs = fromNix $ fromJust $ lookup "nixExprs" $ deploymentAList deployment 
  let machines = filter (\Resource{..} -> resourceType == "ec2") res

  return $ State deployment res exprs machines

deploymentInfo (State deployment _ exprs _) =
    let info = nixDeploymentInfo (exprs) (deploymentUuid deployment)
        in fgconsume info >>= return . nixValue

buildMachines (State deployment _ exprs machines) = do
  physical <- physicalSpecFile machines
  return $ nixBuildMachines (physical:exprs) (deploymentUuid deployment) (map (T.unpack . resourceName) machines) closuresPath

install (State _ _ _ machines) =
    let args m@Resource{..} = (remote m, closuresPath </> (T.unpack resourceName))
        remote m = Remote "/dev/null" (T.unpack $ attr m "publicIpv4")
    in concat [ fmap (uncurry nixCopyClosureTo . args) machines
              , fmap (ssh . uncurry nixSetProfile . args) machines
              , fmap (ssh . nixSwitchToConfiguration . fst . args) machines
              ]

deployPlan s = do
    _ <- deploymentInfo s
    -- TODO: do stuff with info
    build <- buildMachines s
    let inst = install s
    return $ build:inst

main = do 
    s@(State _ resources _ _) <- state
    let keypairs = (\Resource{..} -> resourceType == "ec2-keypair") `filter` resources
    print keypairs
    agentSocket <- randomTempFileName "ssh-agent.sock."
    spawn $ sshAgent agentSocket
    mapM_ (fgrun . sshAddKey agentSocket) $ map (flip attr "privateKey") keypairs
    fgrun $ sshListKeys agentSocket
    deployPlan s >>= mapM_ print
