{ config, lib, pkgs, ... }:

let
  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.services.gow_wolf;
in {
  # Create the main option to toggle the service state
  options.services.gow_wolf.enable = lib.mkEnableOption "gow_wolf";

  # The following are the options we enable the user to configure for this
  # package.
  # These options can be defined or overriden from the system configuration
  # file at /etc/nixos/configuration.nix
  # The active configuration parameters are available to us through the `cfg`
  # expression.

  # When using easyCerts=true the IP Address must resolve to the master on creation.
  # So use simply 127.0.0.1 in that case. Otherwise you will have errors like this https://github.com/NixOS/nixpkgs/issues/59364

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable {
    #######################################################
    # GOW - Wolf Setup
    #######################################################

    # Open selected port in the firewall.
    # We can reference the port that the user configured.
    networking.firewall = {
      enable = true;
      allowPing = true;
      allowedTCPPorts = [
        # Wolf - Game streaming
        47984  # Wolf - https
        47989  # Wolf - http
        48010  # Wolf - rtsp
      ];
      allowedUDPPorts = [
         # Wolf - Game streaming
        47999  # Wolf - Control
        { from = 48100; to = 48110; }  # Wolf - Video (up to 10 users, you can open more ports if needed)
        { from = 48200; to = 48210; }  # Wolf - Audio (up to 10 users, you can open more ports if needed)
      ];
    };

    # Enable Docker
    virtualisation.docker.enable = true;

    # Enable PulseAudio
    sound.enable = true;
    hardware.pulseaudio.enable = true;
    hardware.pulseaudio.support32Bit = true;

    # (Optional) Enable PulseAudio to run as a system-wide service (careful with security implications)
    # services.pulseaudio = {
    #   enable = true;
    #   systemWide = true;
    # };

    # Let the ops user run docker commands without sudo
    #users.extraGroups.docker.members = [ "ops" ];

    # Arion configuration for the Docker Compose setup
    virtualisation.arion.enable = true;
    virtualisation.arion.compositions.wolf = {
      services = {
        wolf = {
          image = "ghcr.io/games-on-whales/wolf:stable";
          environment = {
            XDG_RUNTIME_DIR = "/tmp/sockets";
            HOST_APPS_STATE_FOLDER = "/etc/wolf";
          };
          volumes = [
            "/etc/wolf:/etc/wolf"
            "/tmp/sockets:/tmp/sockets:rw"
            "/var/run/docker.sock:/var/run/docker.sock:rw"
            "/dev:/dev:rw"
            "/run/udev:/run/udev:rw"
          ];
          deviceCgroupRules = [ "c 13:* rmw" ];
          devices = [
            "/dev/dri"
            "/dev/uinput"
            "/dev/uhid"
          ];
          network_mode = "host";
          restart = "unless-stopped";
        };
      };
    };

    # Create the necessary directories
    systemd.tmpfiles.rules = [
      "d /etc/wolf 0755 root root"
      "d /tmp/sockets 0755 root root"
    ];

    virtualisation.docker.daemon.settings = {
      data-root = "/docker/daemon";
    };
  };
}
