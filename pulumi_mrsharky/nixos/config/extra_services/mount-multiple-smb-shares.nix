{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.mount_samba;

  # Build the options list for a share, merging globals + per-share overrides.
  mkShareOptions = share: let
    # if-null helper
    orNull = v: d:
      if v != null
      then v
      else d;

    uid = toString (orNull share.uid cfg.defaultUid);
    gid = toString (orNull share.gid cfg.defaultGid);
    fileMode = orNull share.fileMode cfg.defaultFileMode;
    dirMode = orNull share.dirMode cfg.defaultDirMode;
    vers = orNull share.vers cfg.defaultVers;

    base =
      [
        "_netdev"
        "rw"
        "uid=${uid}"
        "gid=${gid}"
        "file_mode=${fileMode}"
        "dir_mode=${dirMode}"
        "vers=${vers}"
        "sec=ntlmssp"
        "x-systemd.requires=network-online.target"
        "x-systemd.after=network-online.target"
      ]
      ++ lib.optionals share.nofail ["nofail"];

    creds =
      if share.credentialsFile != null
      then ["credentials=${toString share.credentialsFile}"]
      else [
        "username=${orNull share.username ""}"
        "password=${orNull share.password ""}"
      ];

    automount =
      if share.automount
      #then ["x-systemd.automount" "noauto" "x-systemd.idle-timeout=600"] # 10 min
      then ["noauto"]
      else [];
  in
    base ++ creds ++ (share.extraOptions or []) ++ automount;
in {
  options.extraServices.mount_samba = {
    enable = lib.mkEnableOption "mount_samba";

    # Global defaults (per-share can override)
    defaultUid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "Default UID owning files for mounted shares.";
    };

    defaultGid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "Default GID owning files for mounted shares.";
    };

    defaultFileMode = lib.mkOption {
      type = lib.types.str;
      default = "0666";
      description = "Default file mode for mounted shares.";
    };

    defaultDirMode = lib.mkOption {
      type = lib.types.str;
      default = "0777";
      description = "Default dir mode for mounted shares.";
    };

    defaultVers = lib.mkOption {
      type = lib.types.enum ["1.0" "2.0" "2.1" "3.0" "3.02" "3.11"];
      default = "3.11";
      description = "Default SMB protocol version.";
    };

    defaultNofail = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Avoid boot failure if a share is unavailable.";
    };

    automount = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use systemd automount for all shares by default (per-share override available).";
    };

    # Multiple shares keyed by a name you choose
    shares = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({config, ...}: {
        options = {
          path = lib.mkOption {
            type = lib.types.str;
            example = "//192.168.1.51/media";
            description = "CIFS path (//server/share).";
          };

          mountPoint = lib.mkOption {
            type = lib.types.str;
            example = "/mnt/media";
            description = "Local mount point.";
          };

          # Credentials (choose exactly one style)
          username = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "julien";
          };

          password = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "password123";
          };

          credentialsFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            example = "/etc/nixos/secrets/media-cred";
            description = "File containing 'username=..' and 'password=..'.";
          };

          # Per-share overrides
          uid = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
          gid = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
          fileMode = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          dirMode = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          vers = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum ["1.0" "2.0" "2.1" "3.0" "3.02" "3.11"]);
            default = null;
          };
          nofail = lib.mkOption {
            type = lib.types.bool;
            default = cfg.defaultNofail;
          };
          automount = lib.mkOption {
            type = lib.types.bool;
            default = cfg.automount;
          };

          extraOptions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            example = ["iocharset=utf8" "soft"];
            description = "Additional mount options appended as-is.";
          };
        };
      }));
      default = {};
      description = "Map of CIFS shares to mount.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [pkgs.cifs-utils];

    boot.supportedFilesystems = ["cifs"];

    # Make sure mount points exist
    systemd.tmpfiles.rules = lib.concatLists (lib.mapAttrsToList (_n: share: [
        "d ${share.mountPoint} 0755 root root -"
      ])
      cfg.shares);

    # One fileSystems entry per share
    fileSystems = lib.mkMerge (
      lib.mapAttrsToList (_n: share: {
        "${share.mountPoint}" = {
          device = share.path;
          fsType = "cifs";
          options = mkShareOptions share;
        };
      })
      cfg.shares
    );
  };
}
