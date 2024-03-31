{ config, lib, pkgs, ... }:

let

  # Read JSON file
  jsonData = builtins.fromJSON (builtins.readFile ./data.json);

  # Function to generate fileSystems configuration
  generateFileSystems = path: arrays:
    lib.concatMapAttrs (name: value:
      let
        arrayPath = "/mnt/SnapArrays/${path}/${name}";
      in
      {
        "${arrayPath}" = {
          device = value.device;
          fsType = value.fsType;
          options = value.options;
        };
      }
    ) arrays;

  # Generate fileSystems configuration
  fileSystemsConfig = lib.concatMapAttrs (path: arrays: generateFileSystems path arrays) jsonData;

  # Generate the power-up commands
  extractDevices = lib.concatLists (lib.mapAttrsToList (path: arrays:
    lib.concatLists (lib.mapAttrsToList (name: value:
      [ "${pkgs.hdparm}/sbin/hdparm -S 242 ${value.device}" ]
    ) arrays)
  ) jsonData);
  powerManagementCommands = builtins.concatStringsSep "\n" extractDevices;

in

{
  fileSystems = fileSystemsConfig;

  powerManagement = {
    enable = true;
    powerUpCommands = powerManagementCommands;
  };

}
