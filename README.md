Upcast is a declarative cloud infrastructure orchestration tool that leverages [Nix](http://nixos.org/nix/).
Its nix codebase (and, by extension, its interface) was started off by copying files from [nixops](https://github.com/nixos/nixops).

[![Build Status](https://travis-ci.org/zalora/upcast.svg?branch=master)](https://travis-ci.org/zalora/upcast)

### Quick start

```console
upcast - infrastructure orchestratrion

Usage: upcast COMMAND

Available commands:
  run                      evaluate resources, run builds and deploy
  build                    perform a build of all machine closures
  instantiate              perform instantiation of all machine closures
  ssh-config               dump ssh config for deployment (evaluates resources)
  resource-info            dump resource information in json format
  resource-debug           evaluate resources in debugging mode
  nix-path                 print effective path to upcast nix expressions
  install                  install system closure over ssh
```


```console
## see https://github.com/zalora/nixpkgs
$ export NIX_PATH=nixpkgs=/path/to/zalora/nixpkgs:$NIX_PATH

## prepare credentials
$ awk 'NR==1 {print "default", $1, $2}' ~/.ec2-keys > ~/.aws-keys # assuming you used nixops

## build upcast
$ cabal install

## fill in your ec2 vpc account information (look into other examples/ files to provision a VPC)
$ cp examples/ec2-info.nix{.example,}
$ vim examples/ec2-info.nix

## execute the deployment
$ upcast run examples/vpc-nix-instance.nix
```

### Goals

- simplicity, extensibility;
- shared state stored as nix expressions next to machines expressions;
- first-class AWS support (including AWS features nixops doesn't have);
- pleasant user experience and network performance (see below);
- support for running day-to-day operations on deployed resources, services and machines.

### Notable differences from NixOps

#### Expression files

- You can no longer specify the machine environment using `deployment.targetEnv`, now you need to explicitly include the resource module instead.
  Currently available modules are: `<upcast/env-ec2.nix>`.
- You can deploy an EC2 instance that does not use nix in its base AMI by using `deployment.nix = false;` (you won't be able to deploy a nix closure to such machine)>

#### Operation modes

- The only supported command is `run` (so far). No `create`, `modify`, `clone`, `set-args`, `send-keys`.
- NixOps SQLite state files are abandoned, separate text files ([json dict for state](https://github.com/zalora/upcast/blob/master/src/Upcast/TermSubstitution.hs) and a private key file) are used instead;
- Physical specs are removed
  - Identical machines get identical machine closures, they are no longer parametric by things like hostnames (these are configured at runtime).

#### Resources

- New: EC2-VPC support, ELB support;
- Additionally planned: AWS autoscaling, EBS snapshotting;
- Different in EC2: CreateKeyPair (autogenerated private keys by amazon) is not supported, ImportKeyPair is used instead;
- Not supported: sqs, s3, elastic ips, ssh tunnels, adhoc nixos deployments,
                 deployments to expressions that span multiple AWS regions;
- Most likely will not be supported: virtualbox, hetzner, auto-luks, auto-raid0, `/run/keys` support, static route53 support (like nixops);

### Motivation

![motivation](http://i.imgur.com/HY2Gtk5.png)

### Network performance

> tl;dr: do all of these steps if you're using a Mac and/or like visting Starbucks

#### Configuring remote builds

Add the following to your shell profile (this is a must if you are using Darwin, otherwise package builds will fail):

```bash
export NIX_BUILD_HOOK="$HOME/.nix-profile/libexec/nix/build-remote.pl"
export NIX_REMOTE_SYSTEMS="$HOME/remote-systems.conf"
export NIX_CURRENT_LOAD="/tmp/remote-load"
```

`remote-systems.conf` must follow a special format described
in [this Nix wiki page](https://nixos.org/wiki/Distributed_build)
and [chapter 6 of Nix manual](http://nixos.org/nix/manual/#chap-distributed-builds).
`NIX_CURRENT_LOAD` should point to a directory.

#### Making instances download packages from a different host over ssh (a closure cache)

This is useful if one of your remote systems is accessible over ssh and has
better latency to the instance than the machine you run Upcast on.

The key to that host must be already available in your ssh-agent.
Inherently, you also should propagate ssh keys of your instances to that ssh-agent in this case.

```bash
export UPCAST_SSH_AUTH_SOCK=$SSH_AUTH_SOCK
export UPCAST_SSH_CLOSURE_CACHE=nix-ssh@hydra.com
```

#### Adhoc installations

Install NixOS system closure and switch configuration in one command!

```bash
builder=user@hydra.com

# building the whole thing
upcast instantiate examples/vpc-nix-instance.nix | {read drv; nix-copy-closure --to $builder $drv 2>/dev/null && ssh $builder "nix-store --realise $drv 2>/dev/null && cat $(nix-store -qu $drv)"}

# copying store path from the previous build
upcast install -t ec2-55-99-44-111.eu-central-1.compute.amazonaws.com /nix/store/72q9sd9an61h0h1pa4ydz7qa1cdpf0mj-nixos-14.10pre-git
```

#### Unattended builds

No packages build or copied to your host!

(still working on the UX yet :angel:)

```bash
builder=user@hydra.com

upcast instantiate examples/vpc-nix-instance.nix | {read drv; nix-copy-closure --to $builder $drv 2>/dev/null && ssh $builder "nix-store --realise $drv 2>/dev/null && cat $(nix-store -qu $drv)"} | tail -1
env UPCAST_CLOSURES="<paste the above json line here>" \
  UPCAST_SSH_CLOSURE_CACHE=$builder \
  UPCAST_UNATTENDED=1 \
  upcast run examples/vpc-nix-instance.nix
```

#### SSH shared connections

`ControlMaster` helps speed up subsequent ssh sessions by reusing a single TCP connection. See [ssh_config(5)](http://www.openbsd.org/cgi-bin/man.cgi/OpenBSD-current/man5/ssh_config.5?query=ssh_config).

```console
% cat ~/.ssh/config
Host *
    ControlPath ~/.ssh/master-%r@%h:%p
    ControlMaster auto
    ControlPersist yes
```

### Known issues

- you have to use [zalora's fork of nixpkgs with upcast](https://github.com/zalora/nixpkgs)
- state files are not garbage collected, have to be often cleaned up manually;
- altering of most resources is not supported properly (you need to remove using aws cli, cleanup the state file and try again);
- word "aterm" is naming a completely different thing;

Note: the app is currently in HEAVY development (and is already being used to power production cloud instances)
so interfaces may break without notice.

### More stuff

The AWS client code now lives in its own library: [zalora/aws-ec2](https://github.com/zalora/aws-ec2).
