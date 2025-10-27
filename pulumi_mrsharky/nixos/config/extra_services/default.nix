{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./single-node-k3s
    ./cloud-init.nix
    ./desktop-apps.nix
    ./samba_server.nix
    ./glances-service.nix
    ./gow-wolf.nix
    ./gpu.nix
    ./mount-multiple-smb-shares.nix
    ./mount-smb-shares.nix
    ./single-node-kube.nix
  ];
}
