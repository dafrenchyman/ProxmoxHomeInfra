{
  description = "A nixos cloudinit base image without nixos-infect";

  inputs = {
    # Pin to a release branch so you get a stable base (25.05 here)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixos-generators,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
    lib = pkgs.lib;

    # Your base NixOS config as a module
    baseModule = {
      config,
      pkgs,
      lib,
      ...
    }: {
      nixpkgs.hostPlatform = "x86_64-linux";

      imports = [
        "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
      ];

      system.stateVersion = "25.05";

      networking = {
        hostName = "nixos-cloudinit";

        # Use systemd-networkd, let cloud-init adjust details
        useDHCP = false;
        useNetworkd = true;

        defaultGateway = {
          address = "10.1.1.1";
          interface = "eth0";
        };

        interfaces.eth0.useDHCP = false;
      };

      systemd.network.enable = true;

      services.openssh.enable = true;
      services.qemuGuest.enable = true;

      security.sudo.wheelNeedsPassword = false;

      users.users.ops = {
        isNormalUser = true;
        extraGroups = ["wheel"];
      };

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
          cloud_config_mdules:
            - disk_setup
            - mounts
            - set-passwords
            - ssh
          cloud_final_modules: []
        '';
      };

      # NOTE: we intentionally do NOT set fileSystems or boot.loader here.
      # nixos-generators' "qcow-efi" format will create a GPT, ESP, and
      # UEFI bootloader layout for us.
    };
  in {
    # This is what you'll build with: nix build .#image
    packages.${system}.image = nixos-generators.nixosGenerate {
      inherit system;
      format = "qcow-efi"; # UEFI qcow2 image
      modules = [baseModule];
    };
  };
}
