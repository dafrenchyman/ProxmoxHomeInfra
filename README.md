# ProxmoxHomeInfra

The goal of this project is to be able to install a complete system onto [Proxmox](https://proxmox.com/) with the push of a single button.

The main rational for this is I'm tired of having to re-remember everything I've setup when I upgrade my home server. I've dialed in my current server well but when I originally set it up I didn't think much about making it reproducible.

It's still VERY rough around the edges, and there is a lot of dead code in here that needs to be cleaned up/removed.

What I'm trying to accomplish with this repo is:

# The End Result (not there yet)

- You install [Proxmox](https://proxmox.com/) on your home server
  - You then change the settings in `Pulumi.dev.example.yaml` and rename it to `Pulumi.dev.yaml`
  - You also need to make sure you're setup to run stuff via Pulumi
- Run this pulumi script and it'll setup:
  - ✅Setup an ssh key for communicating with Proxmox and VMs that will be generated
  - ✅Export the private key to your `~/.ssh/` folder
  - ✅Remove the enterprise repo
  - ✅Setup a user specific for pulumi installs
  - ✅Setup IOMMU for GPU passthrough
    - **NOTE**: Has only been tested on Intel + Nvidia
  - ✅Setup an API token for Proxmox
  - ✅Setup an Ubuntu cloud-init image
  - ✅Setup a Nixos cloud-init image
    - ❌Create a Nixos samba server
      - **NOTE**: The `nix` config files are here, but haven't been cleaned up yet. I also like [snapraid](https://www.snapraid.it), so I intend to have it run that. That stuff hasn't been cleaned up yet.
  - ❌Setup a VM with both docker and a single node kubernetes node on it with access to the GPU. _(I have this working on an Ubuntu server currently, but I'd like to do it with nixos instead)_
    - ❌Install a bunch of services on the kubernetes node:
      - **NOTE**: Basically all the services I had setup [here](https://github.com/dafrenchyman/home_infra) and some others that I have added over time
    - ❌ Setup [Games on Whales](https://github.com/games-on-whales/gow) ([via wolf](https://github.com/games-on-whales/wolf))
      - **NOTE**: This is the only reason this isn't going to be a pure kubernetes node. I still want access to the GPU to be able to run this. Maybe when this project can be deployed as a helm chart?

Eventually, I'd like to make it so you can just select whatever services you want in the config file so you're then good to go!

# OSX setup

```shell
# gettext lets you run envsubst
brew install gettext
# sshpass lets you connect to ssh with a password file
brew install esolitos/ipa/sshpass
```

Start from scratch after already setting one up:

```shell
pulumi stack rm dev --force --yes
cp Pulumi.dev.example.yaml Pulumi.dev.yaml
```

Fill out all the information in the `yaml` file

# Setup for development:

- Setup a python 3.x venv (usually in `.venv`)
- `pip3 install --upgrade pip`
- Install pip-tools `pip3 install pip-tools`
- Update dev requirements: `pip-compile --output-file=requirements.dev.txt requirements.dev.in`
- Update requirements: `pip-compile --output-file=requirements.txt requirements.in`
- Install dev requirements `pip3 install -r requirements.dev.txt`
- Install requirements `pip3 install -r requirements.txt`
- `pre-commit install`

## Update versions

`pip-compile --output-file=requirements.dev.txt requirements.dev.in --upgrade`
`pip-compile --output-file=requirements.txt requirements.in --upgrade`

# Run `pre-commit` locally.

`pre-commit run --all-files`
