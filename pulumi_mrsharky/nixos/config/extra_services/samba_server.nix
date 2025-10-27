{
  config,
  lib,
  pkgs,
  ...
}:
#############################
# Setup samba server
#############################
# From here:
#  https://nixos.wiki/wiki/Samba
#  https://sourcegraph.com/github.com/Icy-Thought/snowflake/-/blob/modules/networking/samba.nix
#  https://sourcegraph.com/github.com/wkennington/nixos/-/blob/nas/samba.nix
let
  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.extraServices.samba_server;

  # helper: coerce booleans to "yes"/"no" because Samba wants strings
  yesNo = v:
    if builtins.isBool v
    then
      (
        if v
        then "yes"
        else "no"
      )
    else v;

  withDefaults = share:
  # defaults applied first; user's values in `share` override them
  let
    merged =
      {
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = cfg.username;
        "force group" = cfg.username;
      }
      // share;
  in
    lib.mapAttrs (_k: v: yesNo v) merged;
in {
  # Create the main option to toggle the service state
  options.extraServices.samba_server = {
    enable = lib.mkEnableOption "samba_server";

    username = lib.mkOption {
      type = lib.types.str;
      default = "samba-user";
      example = "samba-user";
    };

    password = lib.mkOption {
      type = lib.types.str;
      example = "password123";
    };

    hosts_allow = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1. 192.168.10. 192.168.100. 127.0.0.1 localhost";
      example = "192.168.1. 192.168.10. 192.168.100. 127.0.0.1 localhost";
    };

    server_name = lib.mkOption {
      type = lib.types.str;
      default = "smbnix";
      example = "smbnix";
    };

    shares = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = {};
      example = {
        SnapArrays_rw = {
          path = "/mnt/Bank/SnapArrays";
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "no";
        };
        SnapArrays_ro = {
          path = "/mnt/Bank/SnapArrays";
          browseable = "yes";
          "read only" = "yes";
        };
      };
      description = ''
        Samba shares configuration.
        Keys are share names, values are attribute sets passed directly to `services.samba.shares`.
        You don’t need to repeat `force user` / `force group`, those are automatically set to `fileserver.username`.
      '';
    };
  };

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable (
    let
      # Can put extra conditionals here if needed later
    in {
      environment.systemPackages = with pkgs; [
        hdparm
        parted
        smartmontools
        snapraid

        # Custom packages
        (writeTextFile {
          name = "snapraid_1";
          text = ''
            This is a custom file created by Nix.
            It contains some sample contents.
          '';
          destination = "/mnt/Bank/snapraid.conf";
        })
      ];

      # Increase boot timeout
      #systemd.services."systemd-fsck@.service" = {
      #  environment = {
      #    SYSTEMD_FD_PATH = "/dev/null";
      #  };
      #  serviceConfig.TimeoutSec = "3min";
      #};

      #systemd.services."systemd-mount@.service" = {
      #  serviceConfig.TimeoutSec = "3min";
      #};

      #systemd.services."systemd-logind".serviceConfig.TimeoutSec = "3min";

      #############################
      # Setup samba server
      #############################
      # Frome here:
      #  https://nixos.wiki/wiki/Samba
      #  https://sourcegraph.com/github.com/Icy-Thought/snowflake/-/blob/modules/networking/samba.nix
      #  https://sourcegraph.com/github.com/wkennington/nixos/-/blob/nas/samba.nix

      # Create samba-user group
      users.groups.${cfg.username} = {
        gid = 2000;
      };

      # Create samba-user user
      users.users.${cfg.username} = {
        isSystemUser = true;
        description = "Residence of our Samba guest users";
        group = "${cfg.username}";
        home = "/var/empty";
        createHome = false;
        shell = pkgs.shadow;
        uid = 2000; # Specify the desired UID for the user
      };

      # Create service
      services.samba = {
        enable = true;
        securityType = "user";
        openFirewall = true;
        settings = {
          global = {
            "workgroup" = "WORKGROUP";
            "server string" = "${cfg.server_name}";
            "netbios name" = "${cfg.server_name}";
            "security" = "user";
            "hosts allow" = "${cfg.hosts_allow}";
            "hosts deny" = "0.0.0.0/0";
            "guest account" = "nobody";
            "map to guest" = "bad user";
          };
        };

        # Create the shares (mapAttrs keeps the existing keys)
        shares = lib.mapAttrs (_name: share: withDefaults share) cfg.shares;
      };

      # Extra samba settings
      services.samba-wsdd = {
        enable = true;
        openFirewall = true;
      };

      # Automatically create the cfg.username smbpasswd login info
      system.activationScripts = {
        sambaUserSetup = {
          text = ''
            PATH=$PATH:${lib.makeBinPath [pkgs.samba]}
            export PASS="${cfg.password}"
            export LOGIN="${cfg.username}"
            echo -ne "$PASS\n$PASS\n" | smbpasswd -a -s $LOGIN
          '';
          deps = [];
        };
      };

      #############################
      # Setup NFS (untested)
      #############################
      services.nfs.server.enable = false;

      # Optionally, specify shared directories
      services.nfs.server.exports = ''
        /mnt/Bank/SnapArrays 192.168.10.0/24(rw,sync,no_subtree_check,anonuid=1000,anongid=1000,no_root_squash)
      '';

      networking.firewall.allowedTCPPorts = [2049];

      #############################
      # Create the shared folder only once
      #############################
      # Create the share directory with ownership/permissions at boot
      # Ensure the directory tree exists, even with no mounts yet
      systemd.tmpfiles.rules =
        lib.mapAttrsToList (
          _name: share: let
            path = share.path;
          in "d ${path} 0755 ${cfg.username} ${cfg.username} -"
        )
        cfg.shares;
    }
  );
}
