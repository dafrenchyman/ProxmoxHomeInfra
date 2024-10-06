{ config, lib, pkgs, ... }:

let
  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.services.single_node_kubernetes;

  ip_address = lib.getHostByName "localhost";

in {
  # Create the main option to toggle the service state
  options.services.single_node_kubernetes = {
    enable = lib.mkEnableOption "single_node_kubernetes";

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "nixkube";
      example = "nixkube";
    };

    full_hostname = lib.mkOption {
      type = lib.types.str;
      default = "nixkube.home.arpa";
      example = "nixkube.home.arpa";
    };

    nameserver_ip = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.1";
      example = "192.168.1.1";
    };

    api_server_port = lib.mkOption {
      type = lib.types.int;
      default = 6443;  # Had to change this from the default 8443 because Unifi controller uses that
      example = 6443;
    };

  };

  # The following are the options we enable the user to configure for this
  # package.
  # These options can be defined or overriden from the system configuration
  # file at /etc/nixos/configuration.nix
  # The active configuration parameters are available to us through the `cfg`
  # expression.

  # When using easyCerts=true the IP Address must resolve to the master on creation.
  # So use simply 127.0.0.1 in that case. Otherwise you will have errors like this https://github.com/NixOS/nixpkgs/issues/59364

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable {
    #######################################################
    # Kubernetes setup
    #######################################################

    # Open selected port in the firewall.
    # We can reference the port that the user configured.
    networking.firewall = {
      enable = true;
      allowPing = true;
      allowedTCPPorts = [
        cfg.api_server_port  # Kubernetes
        # Ingress
        80
        443
        8445
        # Unifi
        8443  # Unifi - Web interface + API
        3478  # Unifi - STUN port
        10001  # Unifi - Device discovery
        8080  # Unifi - Contrellor
        1900  # ???
        8843  # Unifi - Captive Portal (https)
        8880  # Unifi - Captive Portal (http)
        6789  # Unifi - Speedtest
        5514  # Unifi - remote syslog
        # Wolf - Game streaming
        47984  # Wolf - https
        47989  # Wolf - http
        48010  # Wolf - rtsp
      ];
      allowedUDPPorts = [
        cfg.api_server_port  # Kubernetes
        # Ingress
        80
        443
        8445
        # Unifi
        8443  # Unifi - Web interface + API
        3478  # Unifi - STUN port
        10001  # Unifi - Device discovery
        8080  # Unifi - Contrellor
        1900  # ???
        8843  # Unifi - Captive Portal (https)
        8880  # Unifi - Captive Portal (http)
        6789  # Unifi - Speedtest
        5514  # Unifi - remote syslog
      ];
    };

    # Required packages
    environment.systemPackages = with pkgs; [
      kompose
      kubectl
      kubernetes
    ];

    # resolve master hostname
    networking.extraHosts = "${ip_address} ${cfg.full_hostname}";

    services.kubernetes = {
      roles = ["master" "node"];
      masterAddress = cfg.full_hostname;
      apiserverAddress = "https://${cfg.full_hostname}:${toString cfg.api_server_port}";
      easyCerts = true;
      apiserver = {
        securePort = cfg.api_server_port;
        advertiseAddress = ip_address;
      };

      # use coredns
      addons.dns.enable = true;

      # needed if you use swap
      kubelet.extraOpts = "--fail-swap-on=false";
    };

    networking = {
      hostName = cfg.hostname;
    };

    # This is required for kubernetes pods to be able to connect out to the internet
    networking.nat.enable = true;

    # Since cloud-init is being used to setup nixos. Kubernetes coredns won't have
    # the correct setting in the "/etc/resolv.conf" file. This will force nixos
    # to write the correct nameserver into the file
    environment.etc = {
      "resolv.conf".text = lib.mkForce  "nameserver ${cfg.nameserver_ip}\n";
    };
  };
}
