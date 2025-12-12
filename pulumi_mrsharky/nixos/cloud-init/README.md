# Creating nixos cloud-init images for use in proxmox

NOTES:

- The code in here is a bit of a mess and needs to be organized.
- I forgot which bit of code gets the `efi` version of a nix image going.
  - I think the `setup.sh` script does it, but honestly: I don't remember
- I need to do more testing on these and figure out which ones are the "good" ones as I was able to get this working.
- The plain `flake.nix` should work fine for a non-efi image.
