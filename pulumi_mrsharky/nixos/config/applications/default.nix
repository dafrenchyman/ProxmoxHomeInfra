{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./codex.nix
    ./openspec.nix
    ./ekpar2.nix
    ./pycharm.nix
  ];
}
