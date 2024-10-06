{ config, lib, pkgs, ... }:

{
  imports = [
    ./glances_service.nix
    ./gow_wolf.nix
    ./single_node_kube.nix
  ];
}
