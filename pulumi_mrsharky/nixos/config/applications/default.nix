{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./openspec.nix
    ./ekpar2.nix
  ];
}
