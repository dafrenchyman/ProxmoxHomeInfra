#!/usr/bin/env bash
# Build flake image
nix --experimental-features 'nix-command flakes' build .#image

# cd to the 'result' folder (that's where the image gets created)
cd result

# Get shell with 'qemu-img'
nix-shell -p qemu

# Convert the 'qcow2' to 'img'
qemu-img convert nixos.qcow2 -O raw nixos.img