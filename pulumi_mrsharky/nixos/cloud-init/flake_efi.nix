{
  description = "A nixos cloudinit base image without nixos-infect";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    inherit (pkgs) lib;

    baseModule = {
      lib,
      config,
      pkgs,
      ...
    }: {
      nixpkgs.hostPlatform = "x86_64-linux";

      imports = [
        "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
      ];

      system.stateVersion = "25.05";

      networking.hostName = "nixos-cloudinit";

      ########################################
      # UEFI layout, following a known-good pattern:
      #   /dev/vda1 -> vfat -> /boot (ESP)
      #   /dev/vda2 -> ext4 -> /    (root)
      ########################################

      fileSystems."/boot" = {
        device = "/dev/vda1";
        fsType = "vfat";
        # no autoFormat here – let make-disk-image handle it
      };

      fileSystems."/" = {
        device = "/dev/vda2";
        fsType = "ext4";
        # no autoResize/autoFormat for now
      };

      boot.growPartition = true;

      ########################################
      # GRUB EFI-only (no BIOS MBR)
      ########################################
      boot.loader.grub = {
        enable = true;
        efiSupport = true;
        efiInstallAsRemovable = true;
        device = "nodev"; # EFI-only, don't touch MBR
      };

      # NO systemd-boot config here
      # (remove boot.loader.systemd-boot.*, boot.loader.efi.*)

      services.openssh.enable = true;

      security.sudo.wheelNeedsPassword = false;

      users.users.ops = {
        isNormalUser = true;
        extraGroups = ["wheel"];
      };

      networking = {
        useDHCP = false;
        useNetworkd = true;

        defaultGateway = {
          address = "10.1.1.1";
          interface = "eth0";
        };

        interfaces.eth0.useDHCP = false;
      };

      systemd.network.enable = true;

      services.cloud-init = {
        enable = true;
        network.enable = true;
        config = ''
          system_info:
            distro: nixos
            network:
              renderers: [ 'networkd' ]
            default_user:
              name: ops
          users:
            - default
          ssh_pwauth: false
          chpasswd:
            expire: false
          cloud_init_modules:
            - migrator
            - seed_random
            - growpart
            - resizefs
          cloud_config_modules:
            - disk_setup
            - mounts
            - set-passwords
            - ssh
          cloud_final_modules: []
        '';
      };
    };

    nixos = nixpkgs.lib.nixosSystem {
      modules = [baseModule];
    };

    make-disk-image = import "${nixpkgs}/nixos/lib/make-disk-image.nix";
  in {
    inherit pkgs;

    image = make-disk-image {
      inherit pkgs lib;
      config = nixos.config;
      name = "nixos-cloudinit";
      format = "qcow2-compressed";

      # Full NixOS image with bootloader installed
      onlyNixStore = false;
      partitionTableType = "legacy+gpt";
      installBootLoader = true;
      touchEFIVars = true;

      diskSize = "auto";
      additionalSpace = "0M";
      copyChannel = true;

      # Give the tiny installer VM more RAM (default is 1024)
      memSize = 2048;
    };
  };
}
