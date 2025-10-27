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

      networking = {
        hostName = "nixos-cloudinit";
      };

      fileSystems."/" = {
        label = "nixos";
        fsType = "ext4";
        autoResize = true;
      };
      boot.loader.grub.device = "/dev/sda";

      services.openssh.enable = true;

      services.qemuGuest.enable = true;

      security.sudo.wheelNeedsPassword = false;

      users.users.ops = {
        isNormalUser = true;
        extraGroups = ["wheel"];
      };

      networking = {
        defaultGateway = {
          address = "10.1.1.1";
          interface = "eth0";
        };
        dhcpcd.enable = false;
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

    # Enable experimental features we'll need
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    make-disk-image = import "${nixpkgs}/nixos/lib/make-disk-image.nix";
  in {
    inherit pkgs;
    image = make-disk-image {
      inherit pkgs lib;
      config = nixos.config;
      name = "nixos-cloudinit";
      format = "qcow2-compressed";
      copyChannel = true;
    };
  };
}
