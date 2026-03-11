{
  config,
  lib,
  pkgs,
  ...
}: let
  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.extraServices.development;
in {
  # Create the main option to toggle the service state
  options.extraServices.development = {
    enable = lib.mkEnableOption "Development Applications";
  };

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable {
    # Packages
    environment.systemPackages = with pkgs; [
      # Development
      gcc
      libgcc
      stdenv.cc.cc.lib
      python3
      python310
      python311
      python312
      python313
    ];

    # nix never adds anything to the LD_LIBRARY_PATH, but we need some stuff in there
    environment.sessionVariables = {
      LD_LIBRARY_PATH = "${pkgs.stdenv.cc.cc.lib}/lib";
    };
  };
}
