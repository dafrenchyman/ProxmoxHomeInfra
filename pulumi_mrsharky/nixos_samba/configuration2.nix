{ config, lib, pkgs, ... }:

let
  glancesConfig = import ./glances {};

in
{
  # Import the qemu-guest.nix file from the nixpkgs repository on GitHub
  #   https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/qemu-guest.nixC
  imports = [
    "${builtins.fetchTarball "https://github.com/nixos/nixpkgs/archive/master.tar.gz"}/nixos/modules/profiles/qemu-guest.nix"
    ./hardware-configuration.nix
    ./glances_with_prometheus/service.nix
  ];

  environment.systemPackages = with pkgs; [
    #(callPackage ./glances/default.nix {}) # custom glances with Prometheus
    # glancesConfig.glancesPackage
    hdparm
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

    # Custom packages
    (writeTextFile {
      name = "snapraid_1";
      text = ''
        This is a custom file created by Nix.
        It contains some sample contents.
      '';
      destination = "/mnt/snapraid.conf";
    })
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


  # Get serial console working
  systemd.services."getty@tty1" = {
    enable = lib.mkForce true;
    wantedBy = [ "getty.target" ]; # to start at boot
    serviceConfig.Restart = "always"; # restart when session is closed
  };

  # Enable experimental features we'll need
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Setup ops user for ssh'ing into the box
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
#  systemd.services.glances = {
#    enable = true;
#    description = "glances web interface";
#    unitConfig = {
#      Type = "simple";
#      After = "network.target";
#    };
#    serviceConfig = {
#      # ExecStart = "glances --export prometheus";
#      # ExecStart = "${pkgs.glances_with_prometheus}/bin/glances --export prometheus";
#      ExecStart = (callPackage ./glances/default.nix {}).bin.glances + " --export prometheus";
#      Restart = "on-abort";
#      RemainAfterExit ="yes";
#    };
#    wantedBy = [ "multi-user.target" ];
#  };

#  environment.etc.glances = rec {
#    target = "glances/glances.conf";
#    text = ''
#      [prometheus]
      # Configuration for the --export prometheus option
      # https://prometheus.io
      # Create a Prometheus exporter listening on localhost:9091 (default configuration)
      # Metric are exporter using the following name:
      #   <prefix>_<plugin>_<stats>{labelkey:labelvalue}
      # Note: You should add this exporter to your Prometheus server configuration:
      #   scrape_configs:
      #    - job_name: 'glances_exporter'
      #      scrape_interval: 5s
      #      static_configs:
      #        - targets: ['localhost:9091']
      #
      # Labels will be added for all measurements (default is src:glances)
      #  labels=foo:bar,spam:eggs
      # You can also use dynamic values
      #  labels=system:`uname -s`
      #
#      host=0.0.0.0
#      port=9091
      #prefix=glances
#      labels=src:glances
#    '';
#  };



  #############################
  # Setup samba server
  #############################
  # Frome here:
  #  https://nixos.wiki/wiki/Samba
  #  https://sourcegraph.com/github.com/Icy-Thought/snowflake/-/blob/modules/networking/samba.nix
  #  https://sourcegraph.com/github.com/wkennington/nixos/-/blob/nas/samba.nix

  # Create samba-user group
  users.groups.samba-user = {
    gid = 2000;
  };

  # Create samba-user user
  users.users.samba-user = {
    isSystemUser = true;
    description = "Residence of our Samba guest users";
    group = "samba-user";
    home = "/var/empty";
    createHome = false;
    shell = pkgs.shadow;
    uid = 2000;  # Specify the desired UID for the user
  };

  # Create service
  services.samba = {
    enable = true;
    securityType = "user";
    openFirewall = true;
    extraConfig = ''
      workgroup = WORKGROUP
      server string = smbnix
      netbios name = smbnix
      security = user
      #use sendfile = yes
      #max protocol = smb2
      # note: localhost is the ipv6 localhost ::1
      hosts allow = 192.168.10. 127.0.0.1 localhost
      hosts deny = 0.0.0.0/0
      guest account = nobody
      map to guest = bad user
    '';
    shares = {
      SnapArrays_rw = {
        path = "/mnt/SnapArrays";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "samba-user";
        "force group" = "samba-user";
      };
      SnapArrays_ro = {
        path = "/mnt/SnapArrays";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "samba-user";
        "force group" = "samba-user";
      };
    };
  };

  # Extra samba settings
  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

   # Automatically create the samba-user smbpasswd login info
  system.activationScripts = {
      sambaUserSetup = {
        text = ''
           PATH=$PATH:${lib.makeBinPath [ pkgs.samba ]}
           export PASS="<REPLACE_ME>"
           export LOGIN="samba-user"
           echo -ne "$PASS\n$PASS\n" | smbpasswd -a -s $LOGIN
            '';
        deps = [ ];
      };
    };


  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [
      9091 # Glances
      61208 # Glances
    ];
    allowedUDPPorts = [
      9091 # Glances
      61208 # Glances
    ];
  };


  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.11";
}
