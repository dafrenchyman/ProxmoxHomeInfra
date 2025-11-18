let
  # Load the JSON file only if it exists
  settingsFile =
    if builtins.pathExists "/etc/nixos/settings.json"
    then builtins.fromJSON (builtins.readFile (toString /etc/nixos/settings.json))
    else {};

  # Default values
  defaultSettings = {
    # Global Settings
    timezone = "America/Los_Angeles";
    gateway = "192.168.10.1";
    domain_name = "home.arpa";
    nameserver_ip = "192.168.10.1";
    username = "nixos";
    password = "";

    internal_network_ip = "";
    internal_network_cidr = 24;

    # "uefi" or "bios"
    boot_mode = "uefi";

    # Cloud-init (default to true since we use a cloud-init image by default)
    cloud_init = {
      enable = true;
    };

    # Customized version of glances
    custom_glances_enable = false;

    # Desktop app
    desktop_apps_enable = false;

    # Samba Fileserver settings
    samba_server = {
      enable = false;
    };

    # Setup GPU
    gpu_enable = false;
    gpu_gpu_type = "";

    # Games on Whales - Wolf
    gow_wolf = {
      enable = false;
      gpu_type = "software";
    };

    # Samba mount settings
    mount_samba = {
      enable = false;
    };

    # Kubernetes Settings
    kube_single_node_enable = false;
    kube_master_ip = "";
    kube_nix_hostname = "";
    kube_master_hostname = "";
    kube_resolv_conf_nameserver = "";
    kube_master_api_server_port = 6443;
    kube_enable_unifi_ports = false;
    kube_enable_plex_ports = false;

    # k3s Settings
    single_node_k3s = {
      enable = false;
      airsonic = {
        enable = false;
      };
      wiki_js = {
        enable = false;
      };
      ubooquity = {
        enable = false;
      };
      unifi = {
        enable = false;
      };
    };
  };

  # Merge attrsets; right-hand wins (overrides)
  settings = defaultSettings // settingsFile;
in
  settings
