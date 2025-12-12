{
  description = "NixOS OVMF + Cloud-Init + Proxmox qcow2 image";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    nixos-generators,
    ...
  }: let
    system = "x86_64-linux";
  in {
    packages.${system}.proxmox-uefi-image = nixos-generators.nixosGenerate {
      inherit system;

      # This is the magic: EFI bootable qcow2
      format = "qcow-efi";

      modules = [
        ({
          config,
          pkgs,
          ...
        }: {
          system.stateVersion = "25.05";
          nixpkgs.hostPlatform = "x86_64-linux";

          # Required for OVMF + GPU passthrough
          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = true;

          boot.loader.grub.enable = false;

          # Cloud-init support
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

          # Enable qemu guest agent
          services.qemuGuest.enable = true;

          # SSH
          services.openssh.enable = true;

          # Networking (cloud-init overrides this)
          networking.useDHCP = true;

          # User
          security.sudo.wheelNeedsPassword = false;
          users.users.ops = {
            isNormalUser = true;
            extraGroups = ["wheel"];
          };

          # VirtIO + firmware
          nixpkgs.config.allowUnfree = true;
          hardware.enableAllFirmware = true;
        })
      ];
    };
  };
}
