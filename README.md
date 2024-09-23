# ProxmoxHomeInfra

The goal of this project is to be able to install a complete system onto [Proxmox](https://proxmox.com/) with the push of a single button.

I'm currently focused on trying to setup a this [Qotom 1U](https://www.amazon.com/dp/B0D5HM6CJX) as this system that contains both a router and a few other VMs for good measure.

This code is messy, experimental, and basically VERY rough around the edges. This is not my best work and is more experimental right now.
There is also a LOT of dead code in here that needs to be cleaned up/removed.

What I'm trying to accomplish with this repo is:

# The End Result (not there yet)

- You install [Proxmox](https://proxmox.com/) on your home server
  - You then change the settings in `Pulumi.dev.example.yaml` and rename it to `Pulumi.dev.yaml`
  - You also need to make sure you're setup to run stuff via Pulumi
- **Run this pulumi script and it'll setup**:
  - ✅Setup an ssh key for communicating with Proxmox and VMs that will be generated
  - ✅Sets up IOMMU
  - ✅Export the private key to your `~/.ssh/` folder
  - ✅Remove the enterprise repo (it's still nagging about it when you login though)
  - ✅Setup a user specific for pulumi installs
  - ✅Setup an API token for Proxmox
  - ✅Install pfsense as a VM and automatically goes through the installer. Setting up a basic WAN/LAN too
    - ✅Done via hardware passthrough for both LAN/WAN ports
    - ✅Installs the unofficial pfsense API so we can send script out doing things
      - **NOTE**: lot more work can be done here to make all the API endpoints usable via Pulumi. I've only gotten some basic ones. Next I need to automate more DNS resolutions to IPs.
    - ✅Changes the default admin user's password
    - ❌Sets up the QEMU agent (broken)
  - ✅Setup a Nixos cloud-init image
  - ✅Installs a Nixos VM via the cloud image
    - ✅Got [Glances](https://github.com/nicolargo/glances) running with a prometheus exporter. The default version for Nixos doesn't do prometheus exporting.
    - ✅Sets it up as a 1 node Kubernetes cluster
      - ✅Got Pulumi to create the `~/.kube/config` contents from the server so it can be used as a `provider` to deploy more Kubernetes service.
      - ✅Self-signed certs working
      - ❌DNS not writing not automatically done to pfsense
      - ✅Got Unifi-controller working via Kubernetes (I like their access points, but I'd rather use this over one of their routers!)
      - ✅Got a simple wikijs helm chart working.
      - ❌... I want to put a lot more small services on here too
        - **NOTE**: Basically all the services I had setup [here](https://github.com/dafrenchyman/home_infra) and some others that I have added over time. I still have a lot more breathing wrong on this little box.
    - ❌ Setup [Games on Whales](https://github.com/games-on-whales/gow) ([via wolf](https://github.com/games-on-whales/wolf))
      - **NOTE**: I really want to mess with wolf on here. I don't think this particular box will do a good job at it, but I want to try it. Hopefully old school emulators may work?
- **I have some older (dead) cde in here that I need to clean up and refactor**
  - ❌Create a Nixos samba server
    - **NOTE**: The `nix` config files are here, but haven't been cleaned up yet. I also like [snapraid](https://www.snapraid.it), so I intend to have it run that. That stuff hasn't been cleaned up yet.
    - **NOTE**: I'm currently doing hardware passthrough of an HBA card so I can directly attach drives from a netapp (I highly recommend going the disk shelf route). You can find them used on ebay for a good price.

# OSX setup

```shell
# gettext lets you run envsubst
brew install gettext
# sshpass lets you connect to ssh with a password file
brew install esolitos/ipa/sshpass
# Install kubectl
brew install kubectl

brew install helm

helm repo add jetstack https://charts.jetstack.io

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

# Notes

Manually remove an entry from pulumi (when things go wrong):

```shell
pulumi state delete
```
