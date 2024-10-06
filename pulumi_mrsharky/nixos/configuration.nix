{ config, lib, pkgs, ... }:

let
  enable_glances = {{ENABLE_GLANCES}};
  enable_single_node_kubernetes = {{ENABLE_KUBE}};
  enable_gow_wolf = {{ENABLE_GOW_WOLF}};
  # When using easyCerts=true the IP Address must resolve to the master on creation.
  # So use simply 127.0.0.1 in that case. Otherwise you will have errors like this https://github.com/NixOS/nixpkgs/issues/59364
  kubeMasterIP = "{{HOST_IP}}";
  nix_hostname = "{{HOSTNAME}}";
  kubeMasterHostname = "{{KUBE_HOSTNAME}}";
  resolvConfNameserver = "{{NAMESERVER}}";
  kubeMasterAPIServerPort = 6443;
in
{
  # Import the qemu-guest.nix file from the nixpkgs repository on GitHub
  #   https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/qemu-guest.nixC
  imports = [
    # arion.nixosModules.arion
    "${builtins.fetchTarball "https://github.com/hercules-ci/arion/archive/refs/tags/v0.2.1.0.tar.gz"}/nixos-module.nix"
    "${builtins.fetchTarball "https://github.com/nixos/nixpkgs/archive/master.tar.gz"}/nixos/modules/profiles/qemu-guest.nix"
    ./glances_with_prometheus/service.nix
    ./extra_services
  ];

  # Packages
  environment.systemPackages = with pkgs; [
    #(callPackage ./glances/default.nix {}) # custom glances with Prometheus
    # glancesConfig.glancesPackage
    mlocate
    nano
    nix
    # python311
    # (python311.withPackages(ps: with ps; [ "glances[all]" prometheus-client ]))
    # python311Packages.glances[all]
    # python311Packages.prometheus-client
    wget
  ];

  fileSystems."/" = {
    label = "nixos";
    fsType = "ext4";
    autoResize = true;
  };
  boot.loader.grub.device = "/dev/sda";

  services.openssh.enable = true;

  services.qemuGuest.enable = true;

  security.sudo.wheelNeedsPassword = false;

  # Get serial console working
  systemd.services."getty@tty1" = {
    enable = lib.mkForce true;
    wantedBy = [ "getty.target" ]; # to start at boot
    serviceConfig.Restart = "always"; # restart when session is closed
  };

  # Enable experimental features we will need
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Setup ops user for sshing into the box
  users.users.ops = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
    ];
  };

  networking = {
    defaultGateway = { address = "10.1.1.1"; interface = "eth0"; };
    dhcpcd.enable = false;
    interfaces.eth0.useDHCP = false;
  };

  systemd.network.enable = true;

  #############################
  # Cloud init
  #############################
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

  # Setup Glances
  extraServices.glances_with_prometheus.enable = enable_glances;

  # Setup Kubernetes
  extraServices.single_node_kubernetes = {
    enable = enable_single_node_kubernetes;
    node_master_ip = kubeMasterIP;
    hostname = nix_hostname;
    full_hostname = kubeMasterHostname;
    nameserver_ip = resolvConfNameserver;
    api_server_port = 6443;
  };

  # Setup Games on Whales - Wolf
  extraServices.gow_wolf.enable = enable_gow_wolf;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.11";
}
