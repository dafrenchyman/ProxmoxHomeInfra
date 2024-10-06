{ config, lib, pkgs, ... }:

let
  # The package itself. It resolves to the package installation directory.
  glances_with_prometheus = pkgs.callPackage ./glances_default.nix {};

  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.extraServices.glances_with_prometheus;

in {

  options.extraServices.glances_with_prometheus = {

    # Create the main option to toggle the service state
    enable = lib.mkEnableOption "glances_with_prometheus";

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      example = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 9091;
    };
  };

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable {
    # Open selected port in the firewall.
    # We can reference the port that the user configured.
    networking.firewall.allowedTCPPorts = [
      cfg.port  # Glances prometheus port
      61208 # Glances
    ];

    networking.firewall.allowedUDPPorts = [
      cfg.port  # Glances prometheus port
      61208 # Glances
    ];

    environment.sessionVariables = rec {
      TERM = "xterm-256color";
    };

    # Setup the /etc/glances/glances.conf file
    environment.etc.glances = rec {
      target = "glances/glances.conf";
      text = ''
        [prometheus]
        host=${cfg.host}
        port=${toString cfg.port}
        #prefix=glances
        labels=src:glances
      '';
    };

    systemd.services.glances_with_prometheus = {
      enable = true;
      description = "glances web prometheus monitoring";
      unitConfig = {
        Type = "simple";
        After = "network.target";
      };
      serviceConfig = {
        ExecStart = "${glances_with_prometheus}/bin/glances -q --export prometheus";
        Restart = "on-abort";
        RemainAfterExit ="yes";
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
