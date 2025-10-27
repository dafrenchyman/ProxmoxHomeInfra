{
  config,
  lib,
  pkgs,
  ...
}: let
  nix_hostname = "{{HOSTNAME}}";
  # When using easyCerts=true the IP Address must resolve to the master on creation.
  # So use simply 127.0.0.1 in that case. Otherwise you will have errors like this https://github.com/NixOS/nixpkgs/issues/59364
  kubeMasterIP = "{{HOST_IP}}";
  kubeMasterHostname = "{{KUBE_HOSTNAME}}";
  resolvConfNameserver = "{{NAMESERVER}}";
  kubeMasterAPIServerPort = 6443;
in {
  # Import the qemu-guest.nix file from the nixpkgs repository on GitHub
  #   https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/qemu-guest.nixC
  imports = [
    "${builtins.fetchTarball "https://github.com/nixos/nixpkgs/archive/master.tar.gz"}/nixos/modules/profiles/qemu-guest.nix"
    ./glances_with_prometheus/service.nix
  ];

  # Packages
  environment.systemPackages = with pkgs; [
    #(callPackage ./glances/default.nix {}) # custom glances with Prometheus
    # glancesConfig.glancesPackage
    hdparm
    kompose
    kubectl
    kubernetes
    mlocate
    nano
    nix
    parted
    # python311
    # (python311.withPackages(ps: with ps; [ "glances[all]" prometheus-client ]))
    # python311Packages.glances[all]
    # python311Packages.prometheus-client
    smartmontools
    snapraid
    wget
  ];

  #######################################################
  # Kubernetes setup
  #######################################################
  # resolve master hostname
  networking.extraHosts = "${kubeMasterIP} ${kubeMasterHostname}";

  services.kubernetes = {
    roles = ["master" "node"];
    masterAddress = kubeMasterHostname;
    apiserverAddress = "https://${kubeMasterHostname}:${toString kubeMasterAPIServerPort}";
    easyCerts = true;
    apiserver = {
      securePort = kubeMasterAPIServerPort;
      advertiseAddress = kubeMasterIP;
    };

    # use coredns
    addons.dns.enable = true;

    # needed if you use swap
    kubelet.extraOpts = "--fail-swap-on=false";
  };

  networking = {
    hostName = nix_hostname;
  };

  # This is required for kubernetes pods to be able to connect out to the internet
  networking.nat.enable = true;

  # Since cloud-init is being used to setup nixos. Kubernetes coredns won't have
  # the correct setting in the "/etc/resolv.conf" file. This will force nixos
  # to write the correct nameserver into the file
  environment.etc = {
    "resolv.conf".text = lib.mkForce "nameserver ${resolvConfNameserver}\n";
  };

  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [
      kubeMasterAPIServerPort # Kubernetes
      # Ingress
      80
      443
      8445
      # Unifi
      8443 # Unifi - Web interface + API
      3478 # Unifi - STUN port
      10001 # Unifi - Device discovery
      8080 # Unifi - Contrellor
      1900 # ???
      8843 # Unifi - Captive Portal (https)
      8880 # Unifi - Captive Portal (http)
      6789 # Unifi - Speedtest
      5514 # Unifi - remote syslog
      # Wolf - Game streaming
      47984 # Wolf - https
      47989 # Wolf - http
      48010 # Wolf - rtsp
    ];
    allowedUDPPorts = [
      kubeMasterAPIServerPort # Kubernetes
      # Ingress
      80
      443
      8445
      # Unifi
      8443 # Unifi - Web interface + API
      3478 # Unifi - STUN port
      10001 # Unifi - Device discovery
      8080 # Unifi - Contrellor
      1900 # ???
      8843 # Unifi - Captive Portal (https)
      8880 # Unifi - Captive Portal (http)
      6789 # Unifi - Speedtest
      5514 # Unifi - remote syslog
    ];
  };

  ##

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
    wantedBy = ["getty.target"]; # to start at boot
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

  #############################
  # Setup Glances
  #############################
  services.glances_with_prometheus.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.11";
}
