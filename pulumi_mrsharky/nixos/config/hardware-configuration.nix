{
  config,
  lib,
  pkgs,
  ...
}: let
  # Read JSON file
  jsonData = builtins.fromJSON (builtins.readFile ./data.json);

  # Function to generate fileSystems configuration
  generateFileSystems = path: arrays:
    lib.concatMapAttrs (
      name: value: let
        arrayPath = "/mnt/Bank/SnapArrays/${path}/${name}";
      in {
        "${arrayPath}" = {
          device = value.device;
          fsType = value.fsType;
          options = value.options;
          neededForBoot = false; # This corresponds to `0` in fstab
        };
      }
    )
    arrays;

  # Generate fileSystems configuration
  fileSystemsConfig = lib.concatMapAttrs (path: arrays: generateFileSystems path arrays) jsonData;

  # Generate the power-up commands
  extractDevices = lib.concatLists (lib.mapAttrsToList (
      path: arrays:
        lib.concatLists (lib.mapAttrsToList (
            name: value: let
              # Remove the '-part1' suffix if it exists
              cleanedDevice = lib.replaceStrings ["-part1"] [""] value.device;
            in ["${pkgs.hdparm}/bin/hdparm -S 242 ${cleanedDevice}"]
          )
          arrays)
    )
    jsonData);
  powerManagementCommands = builtins.concatStringsSep "\n" extractDevices;

  # Generate the power-up commands
  generateHdparmConfig = lib.concatLists (lib.mapAttrsToList (
      path: arrays:
        lib.concatLists (lib.mapAttrsToList (
            name: value: let
              # Remove the '-part1' suffix if it exists
              cleanedDevice = lib.replaceStrings ["-part1"] [""] value.device;
            in ["${cleanedDevice} { spindown_time = 242; }"]
          )
          arrays)
    )
    jsonData);
  hdparmConfig = builtins.concatStringsSep "\n" generateHdparmConfig;

  hdparmPath = "${pkgs.hdparm}/bin/hdparm"; # hdparm installs into /bin in nixpkgs

  # Try setting the powerManagementCommands into a bash file that can be run
  setHdparmScript = pkgs.writeShellScript "set-hdparm" ''
    #!/bin/bash
    ${powerManagementCommands}
  '';
in {
  fileSystems = fileSystemsConfig;

  powerManagement = {
    enable = true;
    powerUpCommands = powerManagementCommands;
  };

  # Write the generated hdparm configuration to /etc/hdparm.conf
  environment.etc."hdparm.conf".text = hdparmConfig;

  services.udev.extraRules = let
    mkRule = as: lib.concatStringsSep ", " as;
    mkRules = rs: lib.concatStringsSep "\n" rs;
  in
    mkRules [
      (mkRule [
        ''ACTION=="add|change"''
        ''SUBSYSTEM=="block"''
        ''KERNEL=="sd[a-z]"''
        ''ATTR{queue/rotational}=="1"''
        ''RUN+="${pkgs.hdparm}/bin/hdparm -B 90 -S 242 /dev/%k"''
      ])
    ];

  systemd.services.set-hdparm = {
    description = "Set hdparm spindown time for drives";
    after = ["local-fs.target"];
    serviceConfig = {
      ExecStart = "${setHdparmScript}";
      Type = "oneshot";
    };
  };
}
