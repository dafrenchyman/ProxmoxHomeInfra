{
  config,
  lib,
  pkgs,
  ...
}: let
  # Load the settings from the secrets file
  settings = import ./settings.nix;

  home-manager = builtins.fetchTarball https://github.com/nix-community/home-manager/archive/release-25.05.tar.gz;

  # Check if an extra username has been setup
  hasValidUser = settings.username != "" && settings.password != "";
in {
  # Import the qemu-guest.nix file from the nixpkgs repository on GitHub
  #   https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/qemu-guest.nixC
  imports = [
    # arion.nixosModules.arion
    (import "${home-manager}/nixos")
    # "${builtins.fetchTarball "https://github.com/hercules-ci/arion/archive/refs/tags/v0.2.1.0.tar.gz"}/nixos-module.nix"
    "${builtins.fetchTarball "https://github.com/nixos/nixpkgs/archive/master.tar.gz"}/nixos/modules/profiles/qemu-guest.nix"
    ./hardware-configuration.nix
    ./extra_services
  ];

  # Location
  time.timeZone = settings.timezone; #"America/Los_Angeles";

  # Packages
  environment.systemPackages = with pkgs; [
    # Terminal Tools
    bat
    dig
    git
    nano
    par2cmdline
    pciutils # For lspci - Since this is a VM we might pass PCI devices to, this helps troubleshoot that
    tmux
    tree
    unrar
    unzip
    wget

    # Docker
    docker
    docker-compose
    kubectl

    # Nix
    nix
  ];

  fileSystems."/" = {
    label = "nixos";
    fsType = "ext4";
    autoResize = true;
  };
  boot.loader.grub.device = "/dev/sda";

  services.openssh.enable = true;

  services.qemuGuest.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  security.sudo.wheelNeedsPassword = false;

  # Get serial console working
  systemd.services."getty@tty1" = {
    enable = lib.mkForce true;
    wantedBy = ["getty.target"]; # to start at boot
    serviceConfig.Restart = "always"; # restart when session is closed
  };

  virtualisation.docker.enable = true;

  # Enable experimental features we will need
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # "download-buffer-size" = 10485760;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  programs.zsh.enable = true;

  # Setup ops group
  users.groups.ops = {
    gid = 1000; # Set the gid
  };

  # users.users.ops = {
  #   isNormalUser = true;
  #   uid = 1000;  # Set the uid
  #   group = "ops";  # Primary group for the user
  #   extraGroups = [
  #     "wheel"
  #   ];
  #   home = "/home/ops";  # Ensure the home directory is set
  # };

  users.users = lib.mkMerge [
    {
      # Setup ops user for ssh'ing into the box
      ops = {
        isNormalUser = true;
        uid = 1000; # Set the uid
        group = "ops"; # Primary group for the user
        extraGroups = [
          "wheel"
        ];
        home = "/home/ops"; # Ensure the home directory is set
      };
    }

    (lib.mkIf hasValidUser (
      lib.genAttrs [settings.username] (_: {
        isNormalUser = true;
        createHome = true;
        group = "ops";
        extraGroups = ["wheel"];
        shell = pkgs.zsh;
        password = settings.password;
        home = "/home/${settings.username}";
      })
    ))
  ];

  networking = {
    # defaultGateway = { address = "10.1.1.1"; interface = "eth0"; };
    dhcpcd.enable = false;
    interfaces.eth0.useDHCP = false;
  };

  systemd.network.enable = true;

  #############################
  # have updatedb run weekly Friday Early Morning
  # This is what populates the `locate` command
  #############################
  services.locate = {
    enable = true;
    interval = "Fri *-*-* 02:15:00";
    package = pkgs.plocate;
    pruneNames = [".bzr" ".cache" ".git" ".hg" ".mozilla" ".npm" ".rbenv" ".svn" ".venv" "Plex Media Server"];
    pruneFS = [
      "afs"
      "anon_inodefs"
      "auto"
      "autofs"
      "bdev"
      "binfmt"
      "binfmt_misc"
      "ceph"
      "cgroup"
      "cgroup2"
      # "cifs"  # We want to scan the mounted systems
      "coda"
      "configfs"
      "cramfs"
      "cpuset"
      "curlftpfs"
      "debugfs"
      "devfs"
      "devpts"
      "devtmpfs"
      "ecryptfs"
      "eventpollfs"
      "exofs"
      "futexfs"
      "ftpfs"
      "fuse"
      "fusectl"
      "fusesmb"
      "fuse.ceph"
      "fuse.glusterfs"
      "fuse.gvfsd-fuse"
      "fuse.mfs"
      "fuse.rclone"
      "fuse.rozofs"
      "fuse.sshfs"
      "gfs"
      "gfs2"
      "hostfs"
      "hugetlbfs"
      "inotifyfs"
      "iso9660"
      "jffs2"
      "lustre"
      "lustre_lite"
      "misc"
      "mfs"
      "mqueue"
      "ncpfs"
      "nfs"
      "NFS"
      "nfs4"
      "nfsd"
      "nnpfs"
      "ocfs"
      "ocfs2"
      "pipefs"
      "proc"
      "ramfs"
      "rpc_pipefs"
      "securityfs"
      "selinuxfs"
      "sfs"
      "shfs"
      "smbfs"
      "sockfs"
      "spufs"
      "sshfs"
      "subfs"
      "supermount"
      "sysfs"
      "tmpfs"
      "tracefs"
      "ubifs"
      "udev"
      "udf"
      "usbfs"
      "vboxsf"
      "vperfctrfs"
    ];
  };

  # systemd.services.updatedb = {
  #   description = "Update mlocate database";
  #   serviceConfig = {
  #     Type = "oneshot";
  #     ExecStart = "${pkgs.mlocate}/bin/updatedb";
  #   };
  # };

  # systemd.timers.updatedb = {
  #   description = "Run updatedb daily";
  #   wantedBy = [ "timers.target" ];
  #   timerConfig = {
  #     OnCalendar = "daily";
  #     Persistent = true;
  #   };
  # };

  #############################
  # Internal Network
  #     For communication between VMs only
  #############################
  # TODO: Automate the creation of this interface in Proxmox creation

  # networking.interfaces.ens19 = {
  #   ipv4.addresses = [
  #     {
  #       address = internal_network_ip;  # Set a static IP for the VM on the internal network
  #       prefixLength = internal_network_cidr;
  #     }
  #   ];
  # bridge = null;  # Ensure this interface is not bridged to a physical interface.
  # mtu = 1500;
  # enable = true;
  # };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "25.05";

  #############################
  # Extra Services
  #############################

  # Cloud Init
  extraServices.cloud_init = settings.cloud_init;

  # Desktop apps
  extraServices.desktop_apps.enable = settings.desktop_apps_enable;

  # Setup Glances
  # extraServices.glances_with_prometheus.enable = settings.custom_glances_enable;

  # Setup Samba Fileserver
  extraServices.samba_server = settings.samba_server;

  # Setup Games on Whales - Wolf
  extraServices.gow_wolf.enable = settings.gow_wolf_enable;
  extraServices.gow_wolf.gpu_type = settings.gow_wolf_gpu_type;

  # Setup GPU
  extraServices.gpu.enable = settings.gpu_enable;
  extraServices.gpu.gpu_type = settings.gpu_type;

  # Mount SMB Shares
  extraServices.mount_samba = settings.mount_samba;

  # Setup Kubernetes
  extraServices.single_node_kubernetes = {
    enable = settings.kube_single_node_enable;
    node_master_ip = settings.kube_master_ip;
    hostname = settings.kube_nix_hostname;
    full_hostname = settings.kube_master_hostname;
    nameserver_ip = settings.kube_resolv_conf_nameserver;
    api_server_port = settings.kube_master_api_server_port;
  };

  # Setup K3s
  extraServices.single_node_k3s = settings.single_node_k3s;

  #####################
  # Home Manager
  #####################
  # home-manager.users.ops = { pkgs, ... }: {
  #   home.packages = [ pkgs.atool pkgs.httpie ];

  #   # The state version is required and should stay at the version you
  #   # originally installed.
  #   home.stateVersion = "25.05";

  #   programs.fzf = {
  #     enable = true;
  #     enableBashIntegration = true;
  #     enableZshIntegration = true;
  #     # tmux.enableShellIntegration = true;
  #     defaultOptions = [
  #       "--no-mouse"
  #     ];
  #   };

  #   programs.zsh = {
  #     enable = true;
  #     enableCompletion = true;
  #     autosuggestion.enable = true;

  #     syntaxHighlighting.enable = true;
  #     # history.append = true;
  #     history.expireDuplicatesFirst = true;
  #     history.findNoDups = true;
  #     history.ignoreAllDups = true;
  #     history.ignoreSpace = true;  # Do not enter command lines into the history list that start with a space

  #     oh-my-zsh = {
  #       enable = true;
  #       plugins = [
  #         "docker"
  #         "docker-compose"
  #         "fzf"
  #         "git"
  #         "npm"
  #         "node"
  #         "z"
  #       ];  # Plugins to use
  #       theme = "";  # disable oh-my-zsh prompt theme
  #     };

  #     initContent = ''
  #       # Tell oh-my-zsh to not set its own prompt
  #       unsetopt promptcr

  #       # Set up oh-my-posh as prompt
  #       # eval "$(oh-my-posh init zsh --config ~/.poshthemes/jandedobbeleer.omp.json)"

  #       # Fix caja thumbnail issue
  #       export OPENBLAS_NUM_THREADS=1

  #     '';

  #   };

  #   programs.tmux = {
  #     enable = true;
  #     shell = "${pkgs.zsh}/bin/zsh";
  #     mouse = true;
  #     terminal = "tmux-256color";
  #     extraConfig = ''
  #       set -g history-limit 10000
  #       set -g default-terminal "tmux-256color"
  #       set -ga terminal-overrides ",xterm-256color:Tc"
  #     '';
  #   };

  #   # Use this for the terminal theme
  #   programs.oh-my-posh = {
  #     enable = true;
  #     enableZshIntegration = true;
  #     enableBashIntegration = false;
  #     useTheme = "powerlevel10k_rainbow";
  #   };

  #   programs.autojump = {
  #     enable = true;
  #     enableZshIntegration = true;
  #     enableBashIntegration = false;
  #   };

  # };
}
