{
  config,
  lib,
  pkgs,
  ...
}:
#############################
# Mount Samba Shares
#############################
let
  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.extraServices._mount_samba;
in {
  # Create the main option to toggle the service state
  options.extraServices._mount_samba = {
    enable = lib.mkEnableOption "mount_samba";

    username = lib.mkOption {
      type = lib.types.str;
      example = "username";
    };

    password = lib.mkOption {
      type = lib.types.str;
      example = "password123";
    };

    path = lib.mkOption {
      type = lib.types.str;
      example = "//192.168.1.51/my_share";
    };

    mount_location = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/my_share";
    };
  };

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      cifs-utils
    ];

    fileSystems."${cfg.mount_location}" = {
      device = "${cfg.path}";
      fsType = "cifs";
      options = [
        "username=${cfg.username}"
        "password=${cfg.password}"
        "uid=1000" # Set ownership to your user (default: 1000)
        "gid=1000" # Set group ownership to your user group (default: 100)
        "file_mode=0666"
        "dir_mode=0777"
        "vers=3.0" # Ensure compatibility with your SMB server
        "nofail" # Avoid boot failure if the share is unavailable
      ];
    };
  };
}
