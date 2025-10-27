# ProxmoxHomeInfra

The goal of this project is to be able to install a complete system onto [Proxmox](https://proxmox.com/) with the push of a single button.

# New System

I'm now trying to get this [GMKtec Mini PC](https://www.amazon.com/dp/B0CQ4WBV8L) to install everything.

- For now I removed the router component from it and I actually don't like pulumi's `__main__.py` functionality as it makes it hard to debug.
  - Instead, There is now a `server_mini.py` file in here that is used to launch everything.
- I'm also now using k3s for kubernetes as nixos uses the "rancher" system for it which lets you copy over your kubernetes `.yaml` files to `var/lib/rancher/k3s/server/manifests/` for installation.
  - I just create these files with specific settings via `.nix` files now. Much simpler than trying to use pulumi's system to install charts and such.
  - This lets you generate normal `.yaml` files and is way easier to debug.
- To install
  - I have an example [.json](./server_mini_example.json) that you'll need to rename to `server_mini.json` and modify to install for your hardware.
    - Modify it to your liking.
- Here's what it currently does:
  - ✅Setup an ssh key for communicating with Proxmox and VMs that will be generated
  - ✅Sets up IOMMU
  - ✅Export the private key to your `~/.ssh/` folder
  - ✅Remove the enterprise repo (it's still nagging about it when you login though)
  - ✅Setup a user specific for pulumi installs
  - ✅Setup an API token for Proxmox
  - ❌Install pfsense as a VM and automatically goes through the installer. Setting up a basic WAN/LAN too
    - Code is still here, but not currently being used. I will eventually add this back in as the mini PC as 2 network port so I should be able to set 1 up as a WAN.
      - Done via hardware passthrough for both LAN/WAN ports
      - Installs the unofficial pfsense API so we can send script out doing things
        - **NOTE**: lot more work can be done here to make all the API endpoints usable via Pulumi. I've only gotten some basic ones. Next I need to automate more DNS resolutions to IPs.
      - Changes the default admin user's password
      - Sets up the QEMU agent (broken)
  - ✅Setup a Nixos cloud-init image
  - ✅Installs a Nixos VM via the cloud images
    - ✅Sets up a simple samba-server nixos image.
      - Eventually I'll move this to another piece of hardware that has access to an HBA to mount hard drives from a JBOD.
        - It already does work, just not with how things are currently setup. You just need PCI passthrough the HBA and properly mount the hard drives. The old [example.yaml](Pulumi.dev.example.yaml) file has an example of how to define the hard drives to mount, you'll just need to add that to the `"drive_mounts": {}` key.
      - I like to keep my fileserver separate from other VMs as this is usually more "rock-solid" while other VMs have a greater tendency to crash and need restarting.
    - ✅Sets it up as a 1 node Kubernetes cluster (... one day there will be multiple nodes)
      - ✅Got Pulumi to create the contents of the `~/.kube/config` file, however the file will be named after the vm to not override existing an `config` file.
      - ✅Self-signed certs working
      - ❌DNS not writing not automatically done to pfsense
      - ✅Got a bunch of services up and running, you can view them all [here](./pulumi_mrsharky/nixos/config/extra_services/single-node-k3s)
        - I'm trying to do the best to automatically grab service information for both prometheus exporters and [homepage](https://gethomepage.dev) via `annotations`.
        - So, if you install both [homepage.nix](./pulumi_mrsharky/nixos/config/extra_services/single-node-k3s/homepage.nix) and [monitoring.nix](./pulumi_mrsharky/nixos/config/extra_services/single-node-k3s/monitoring.nix) (Grafana and Prometheus) it should add them to homepage and add monitoring if available.
        - There are still a lot more services I want to add here
    - ✅ Setup [Games on Whales](https://github.com/games-on-whales/gow) ([via wolf](https://github.com/games-on-whales/wolf))
      - There is still some manual setup that needs to be done with pins to enable clients: so not perfect.
    - **NOTE**: If you change the kubernetes setup, you'll need to manually run the `nixos-rebuild switch` command on the kubernetes VM as I haven't worked out how to get pulumi to re-run it on changes yet.

# The Old System (some of this code is still around)

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
- **I have some older (dead) code in here that I need to clean up and refactor**
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

rancher, manually remove a stuck chart and restart it (wikijs as example):

```
kubectl -n kube-system delete helmchart wikijs
sudo cat /var/lib/rancher/k3s/server/manifests/10-wikijs-helmchart.yaml | kubectl apply -f -
kubectl -n kube-system delete helmchart transmission-openvpn
sudo cat /var/lib/rancher/k3s/server/manifests/10-plex-helmchart.yaml | kubectl apply -f -
```
