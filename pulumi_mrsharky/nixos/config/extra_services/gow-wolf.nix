{
  config,
  lib,
  pkgs,
  ...
}: let
  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.extraServices.gow_wolf;
in {
  # Create the main option to toggle the service state
  options.extraServices.gow_wolf = {
    enable = lib.mkEnableOption "gow_wolf";

    # Other options to go here
    gpu_type = lib.mkOption {
      type = lib.types.enum ["amd" "nvidia" "software"];
      default = "software";
      example = "amd";
      description = "Which GPU backend to use.";
    };

    roms_folder_location = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/ROMs";
      example = "/mnt/ROMs";
      description = "Folder location of ROMs root folder (symbolic links will be created linking /ROMs to this folder)";
    };

    wolf_url = lib.mkOption {
      type = lib.types.str;
      default = "http://192.168.10.12:3000";
      example = "http://192.168.10.12:3000";
      description = "URL location of Wolf";
    };
  };

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable (
    let
      # The docker-compose.yml file (as a JSON)
      wolfDevices =
        if cfg.gpu_type == "amd"
        then [
          "/dev/dri"
        ]
        else if cfg.gpu_type == "nvidia"
        then [
          "/dev/dri"
          "/dev/nvidia-uvm"
          "/dev/nvidia-uvm-tools"
          #"/dev/nvidia-caps/nvidia-cap1"
          #"/dev/nvidia-caps/nvidia-cap2"
          "/dev/nvidiactl"
          "/dev/nvidia0"
          "/dev/nvidia-modeset"
        ]
        else [];

      wolfEnvironmentBase = [
        "XDG_RUNTIME_DIR=/tmp/sockets"
        "HOST_APPS_STATE_FOLDER=/etc/wolf"
        "WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock"
      ];

      wolfEnvironment =
        wolfEnvironmentBase
        ++ (
          if cfg.gpu_type == "software"
          then [
            "WOLF_RENDER_NODE=software"
          ]
          else if cfg.gpu_type == "nvidia"
          then [
            "NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol"
          ]
          else []
        );

      wolfVolumes =
        (
          if cfg.gpu_type == "nvidia"
          then ["nvidia-driver-vol:/usr/nvidia:rw"]
          else []
        )
        ++ [
          "/etc/wolf/:/etc/wolf:rw"
          "/tmp/sockets:/tmp/sockets:rw"
          "/var/run/docker.sock:/var/run/docker.sock:rw"
          "/dev/:/dev/:rw"
          "/run/udev:/run/udev:rw"
          "/var/run/wolf:/var/run/wolf:rw"
        ];

      # TOP-LEVEL volumes (for nvidia)
      nvidiaTopLevelVolumes =
        if cfg.gpu_type == "nvidia"
        then {
          volumes = {
            "nvidia-driver-vol" = {
              external = true;
            };
          };
        }
        else {};

      dockerComposeConfig =
        {
          version = "3";
          services = {
            wolf = {
              #image = "ghcr.io/games-on-whales/wolf:sha-90c8806";
              image = "ghcr.io/games-on-whales/wolf:sha-2984c2b";
              environment = wolfEnvironment;
              volumes = wolfVolumes;
              device_cgroup_rules = ["c 13:* rmw"];
              devices =
                wolfDevices
                ++ [
                  "/dev/uinput"
                  "/dev/uhid"
                ];
              network_mode = "host";
              restart = "unless-stopped";
            };

            wolfmanager = {
              image = "ghcr.io/games-on-whales/wolfmanager/wolfmanager:latest";
              ports = ["3000:3000"];
              environment = [
                "NODE_ENV=debug"
                "NEXTAUTH_URL=${cfg.wolf_url}"
              ];
              volumes = [
                "/var/run/wolf:/var/run/wolf"
                "/var/run/docker.sock:/var/run/docker.sock"
                "/etc/wolf/manager/config:/app/config"
              ];
              restart = "unless-stopped";
            };
          };
        }
        // nvidiaTopLevelVolumes; # merge nvidia named volume at ROOT level
    in {
      #######################################################
      # GOW - Wolf Setup
      #######################################################
      # Required packages
      environment.systemPackages = with pkgs; [
        curl
        docker
        docker-compose
      ];

      # Open selected port in the firewall.
      # We can reference the port that the user configured.
      networking.firewall = {
        allowedTCPPorts = [
          # Wolf - Game streaming
          3000 # Wolf - Manager
          47984 # Wolf - https
          47989 # Wolf - http
          48010 # Wolf - rtsp
        ];
        allowedUDPPorts = [
          # Wolf - Game streaming
          3000 # Wolf - Manager
          47999 # Wolf - Control
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
      services.pulseaudio = {
        enable = true;
        support32Bit = true;
      };

      # Extra groups (not entirely sure this is needed)
      users.groups.ops.gid = 1000;
      users.extraUsers.ops.extraGroups = ["audio" "ops"];

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
        # "d /ROMs 0755 ops users"
      ];

      virtualisation.docker.daemon.settings = {
        data-root = "/docker/daemon";
      };

      environment.etc."wolf/docker-compose.yml".text = builtins.toJSON dockerComposeConfig;

      # Build out the nvidia-driver-vol if gpu is nvidia
      systemd.services.nvidiaDriverVolumeSetup = lib.mkIf (cfg.gpu_type == "nvidia") {
        description = "One-time NVIDIA driver Docker volume builder for GOW";
        wantedBy = ["multi-user.target"];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "build-nvidia-volume" ''
            set -euo pipefail

            MARKER=/etc/wolf/.nvidia-driver-vol-ready

            # Not sure if this "NVIDIA_CAPS" is needed
            #NVIDIA_CAPS=/dev/nvidia-caps
            #if [ ! -d "$NVIDIA_CAPS" ]; then
            #  echo "Building NVIDIA-CAPS"
            #  nvidia-container-cli --load-kmods info
            #fi

            if [ -f "$MARKER" ]; then
              echo "NVIDIA driver volume already built. Skipping."
              exit 0
            fi

            echo "Building NVIDIA driver volume - Started"
            ${pkgs.curl}/bin/curl https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile \
              | ${pkgs.docker}/bin/docker build -t gow/nvidia-driver:latest -f - --build-arg NV_VERSION=$(cat /sys/module/nvidia/version) .
            ${pkgs.docker}/bin/docker create --rm --mount source=nvidia-driver-vol,destination=/usr/nvidia gow/nvidia-driver:latest sh

            echo "Building NVIDIA driver volume - Finished"
            touch "$MARKER"
          '';
        };

        # Ensure it runs after Docker is ready
        after = ["docker.service"];
        before = ["wolf.service"];
        requires = ["docker.service"];
      };

      # Ensure the wolf service is started via docker-compose
      systemd.services.wolf = {
        description = "Wolf Docker Compose Service";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f /etc/wolf/docker-compose.yml up";
          ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f /etc/wolf/docker-compose.yml down";
          Restart = "on-failure";
          WorkingDirectory = "/etc/wolf";
        };

        # Make sure we don't start it until docker is up (and nvidia volume setup)
        after = ["docker.service"] ++ lib.optional (cfg.gpu_type == "nvidia") "nvidiaDriverVolumeSetup.service";
        requires = ["docker.service"] ++ lib.optional (cfg.gpu_type == "nvidia") "nvidiaDriverVolumeSetup.service";
      };
    }
  );
}
