{ config, lib, pkgs, ... }:

let
  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.extraServices.gow_wolf;
in {
  # Create the main option to toggle the service state
  options.extraServices.gow_wolf = {
    enable = lib.mkEnableOption "gow_wolf";

    # Other options to go here
  };

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable {
    #######################################################
    # GOW - Wolf Setup
    #######################################################
    # Required packages
    environment.systemPackages = with pkgs; [
      docker-compose
#      pkgs.arion
#      grim # screenshot functionality
#      slurp # screenshot functionality
#      wl-clipboard # wl-copy and wl-paste for copy/paste from stdin / stdout
#      mako # notification system developed by swaywm maintainer
#      sway                # Wayland compositor
#      wayland             # Wayland itself
#      xwayland            # X server support under Wayland
#      wayland-utils
    ];

    # Enable the gnome-keyring secrets vault.
    # Will be exposed through DBus to programs willing to store secrets.
#    services.gnome.gnome-keyring.enable = true;
#
#    # enable Sway window manager
#    programs.sway = {
#      enable = true;
#      wrapperFeatures.gtk = true;
#    };
#    services.xserver.enable = true;
#
#    # Enable the display manager (e.g., LightDM or GDM)
#    services.xserver.displayManager = {
#      gdm.enable = true;     # Enable GDM for Wayland sessions
#      defaultSession = "sway"; # Ensure the default session starts Sway (optional)
#    };

    # Open selected port in the firewall.
    # We can reference the port that the user configured.
    networking.firewall = {
      allowedTCPPorts = [
        # Wolf - Game streaming
        47984  # Wolf - https
        47989  # Wolf - http
        48010  # Wolf - rtsp
      ];
      allowedUDPPorts = [
         # Wolf - Game streaming
        47999  # Wolf - Control
        48100
        48101
        48102
        48103
        48104
        48105
        48106
        48107
        48108
        48109
        48110
        48200
        48201
        48202
        48203
        48204
        48205
        48206
        48207
        48208
        48209
        48210
        #(lib.range 48100 48110)
        #(lib.range 48200 48210)
        #{ from = 48100; to = 48110; }  # Wolf - Video (up to 10 users, you can open more ports if needed)
        #{ from = 48200; to = 48210; }  # Wolf - Audio (up to 10 users, you can open more ports if needed)
      ];
    };

    # Enable Docker
    virtualisation.docker.enable = true;

    # Enable PulseAudio
    sound.enable = true;
    hardware.pulseaudio.enable = true;
    hardware.pulseaudio.support32Bit = true;

    # Extra groups (not entirely sure this is needed)
    users.groups.ops.gid = 1000;
    users.extraUsers.ops.extraGroups = [ "audio" "ops"];

    # (Optional) Enable PulseAudio to run as a system-wide service (careful with security implications)
    # services.pulseaudio = {
    #   enable = true;
    #   systemWide = true;
    # };

    # Let the ops user run docker commands without sudo
    #users.extraGroups.docker.members = [ "ops" ];

    # Create the necessary directories
    systemd.tmpfiles.rules = [
      "d /etc/wolf 0755 root root"
      "d /tmp/sockets 0755 root root"
      "d /ROMs 0755 ops users"
    ];

    virtualisation.docker.daemon.settings = {
      data-root = "/docker/daemon";
    };

    # Ensure the wolf service is started via docker-compose
    systemd.services.wolf = {
      description = "Wolf Docker Compose Service";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f /etc/wolf/docker-compose.yml up";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f /etc/wolf/docker-compose.yml down";
        Restart = "on-failure";
        WorkingDirectory = "/etc/wolf";
      };

      # Make sure we don't start it until docker is up
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
    };

    # The docker-compose.yml file
    environment.etc."wolf/docker-compose.yml".text = ''
      version: "3"
      services:
        wolf:
          image: ghcr.io/games-on-whales/wolf:stable
          environment:
            - XDG_RUNTIME_DIR=/tmp/sockets
            - HOST_APPS_STATE_FOLDER=/etc/wolf
            - WOLF_RENDER_NODE=software
          volumes:
            - /etc/wolf/:/etc/wolf
            - /tmp/sockets:/tmp/sockets:rw
            - /var/run/docker.sock:/var/run/docker.sock:rw
            - /dev/:/dev/:rw
            - /run/udev:/run/udev:rw
          device_cgroup_rules:
            - 'c 13:* rmw'
          devices:
            # - /dev/dri
            - /dev/uinput
            - /dev/uhid
          network_mode: host
          restart: unless-stopped
    '';

  };
}
