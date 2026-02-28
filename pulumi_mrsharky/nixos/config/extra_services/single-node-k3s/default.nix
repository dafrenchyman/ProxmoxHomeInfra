{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s;

  # Helper method to indent strings
  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    # prefix first line, and after every newline
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  # #######################
  # Ingress
  # #######################
  ingressHelmChart = pkgs.writeText "ingress-nginx-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: ingress-nginx
      namespace: kube-system
    spec:
      repo: https://kubernetes.github.io/ingress-nginx
      chart: ingress-nginx
      version: 4.11.2
      targetNamespace: kube-system
      # Values mirror your Pulumi config
      valuesContent: |
        controller:
          hostNetwork: true
          hostPorts:
            http: 80
            https: 443
          service:
            type: ClusterIP
          admissionWebhooks:
            enabled: true
            port: 8445
            patch:
              enabled: true
              webhook:
                port: 8445
  '';

  # #######################
  # Cert Manager
  # #######################
  certManagerNamespace = pkgs.writeText "00-cert-manager-namespace.yaml" ''
    apiVersion: v1
    kind: Namespace
    metadata:
      name: cert-manager
  '';

  certManagerHelmChart = pkgs.writeText "10-cert-manager-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: cert-manager
      namespace: kube-system
    spec:
      repo: https://charts.jetstack.io
      chart: cert-manager
      version: v1.17.0
      targetNamespace: cert-manager
      valuesContent: |
        crds:
          enabled: true
          keep: true
        # Optional hardening knobs you might like later:
        # global:
        #   leaderElection:
        #     namespace: cert-manager

  '';

  certManagerIssuers = pkgs.writeText "20-cert-manager-issuers.yaml" ''
    ---
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: selfsigned-cluster-issuer
    spec:
      selfSigned: {}
    ---
    # Root CA, signed by the self-signed ClusterIssuer above
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: ca-root-cert
      namespace: cert-manager
    spec:
      isCA: true
      commonName: my-ca
      duration: 8760h     # 1 year
      secretName: ca-root-cert-secret
      issuerRef:
        name: selfsigned-cluster-issuer
        kind: ClusterIssuer
    ---
    # A namespaced Issuer that uses the root CA secret for signing leaf certs
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: ca-cluster-issuer
    spec:
      ca:
        secretName: ca-root-cert-secret
  '';

  # #######################
  # MetalLB
  # #######################

  # Namespace
  metallbNamespace = pkgs.writeText "00-metallb-namespace.yaml" ''
    apiVersion: v1
    kind: Namespace
    metadata:
      name: metallb-system
  '';

  # HelmChart
  metallbHelmChart = pkgs.writeText "10-metallb-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: metallb
      namespace: kube-system
    spec:
      repo: https://metallb.github.io/metallb
      chart: metallb
      version: 0.15.3
      targetNamespace: metallb-system
      valuesContent: |
        crds:
          enabled: true
  '';

  # The below didn't work for generating the address block (although it seems cleaner
  # ${indent 8 (lib.generators.toYAML {} cfg.addresses)}

  # Build the addresses block as dash-prefixed lines (this does seem to work)
  addressesBlock = indent 4 (builtins.concatStringsSep "\n" (map (a: "- " + a) cfg.addresses));

  # ADD: IPAddressPool + L2Advertisement (Layer2 ARP)
  metallbPool = pkgs.writeText "20-metallb-address-pool.yaml" ''
    apiVersion: metallb.io/v1beta1
    kind: IPAddressPool
    metadata:
      name: ${cfg.poolName}
      namespace: metallb-system
    spec:
      addresses:
    ${addressesBlock}
    ---
    apiVersion: metallb.io/v1beta1
    kind: L2Advertisement
    metadata:
      name: ${cfg.poolName}-l2
      namespace: metallb-system
    spec:
      ipAddressPools:
        - ${cfg.poolName}
  '';

  # #######################
  # Cloud Native Postgres
  # #######################

  # Namespace
  postgresCloudNativeNamespace = pkgs.writeText "00-postgres-cloud-native-namespace.yaml" ''
    apiVersion: v1
    kind: Namespace
    metadata:
      name: cnpg-system
  '';

  # Helm Chart
  postgresCloudNativeHelmChart = pkgs.writeText "10-postgres-cloud-native-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: cloudnative-pg
      namespace: kube-system
    spec:
      repo: https://cloudnative-pg.github.io/charts
      chart: cloudnative-pg
      version: 0.27.1
      targetNamespace: cnpg-system
  '';
in {
  imports = [
    ./airsonic.nix
    ./audiobookshelf.nix
    ./gitea.nix
    ./homepage.nix
    ./immich.nix
    ./jellyfin.nix
    ./komga.nix
    ./monitoring.nix
    ./nzbget.nix
    ./open-webui.nix
    ./plex.nix
    ./termix.nix
    ./transmission-openvpn.nix
    ./trilium.nix
    ./ubooquity.nix
    ./unifi.nix
    ./virtual-tabletop.nix
    ./wiki-js.nix
  ];

  options.extraServices.single_node_k3s = {
    enable = lib.mkEnableOption "single-node k3s cluster";

    node_master_ip = lib.mkOption {
      type = lib.types.str;
      example = "192.168.10.10";
    };

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
      default = 6443;
      example = 6443;
    };

    # MetalLB Options
    poolName = lib.mkOption {
      type = lib.types.str;
      default = "pool1";
      description = "Name for the MetalLB IPAddressPool.";
    };

    # List of CIDR blocks or start-end ranges as strings
    addresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["192.168.10.51-192.168.10.54"];
      example = ["192.168.10.50-192.168.10.60" "192.168.10.70/32"];
      description = ''
        Address ranges MetalLB can hand out (e.g. "192.168.10.50-192.168.10.60" or "192.168.10.70/32").
        These must be on the same L2 network as your nodes.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    #######################################################
    # System tweaks
    #######################################################

    # Setting up an in memory swap (instead of a regular swap partition
    zramSwap.enable = true;
    zramSwap.memoryPercent = 25;

    boot.kernel.sysctl = {
      "vm.dirty_background_ratio" = 3;
      "vm.dirty_ratio" = 5;
      "vm.min_free_kbytes" = 65536;
      "vm.vfs_cache_pressure" = 500;
    };

    # TODO: Need to try to enable the firewall
    networking.firewall = {
      enable = false;
      allowPing = true;
      allowedTCPPorts = [
        cfg.api_server_port
        53
        80
        443
        8445
      ];
      allowedUDPPorts = [
        cfg.api_server_port
        53
        80
        443
        8445
      ];
    };

    environment.systemPackages = with pkgs; [
      kubectl
      helm
      vmtouch
      # (k3s binaries are managed by the service)
    ];

    networking.hostName = cfg.hostname;

    # resolve master hostname
    networking.extraHosts = "${cfg.node_master_ip} ${cfg.full_hostname}";

    # This is required for kubernetes pods to be able to connect out to the internet
    networking.nat.enable = true;

    # Since cloud-init is being used to setup nixos. Kubernetes coredns won't have
    # the correct setting in the "/etc/resolv.conf" file. This will force nixos
    # to write the correct nameserver into the file
    environment.etc = {
      "resolv.conf".text = lib.mkForce "nameserver ${cfg.nameserver_ip}\n";
    };

    # Setup DNS - This allows the server to accept all traffic to "full_hostname"
    #             and route the requests to the correct service
    services.dnsmasq = {
      enable = true;

      settings = {
        # Bind directly to the node’s LAN IP (no need to know eth0/enpXsY/etc)
        listen-address = [cfg.node_master_ip];

        #interface = "eth0"; # replace with your actual interface, or use "lo" for localhost only
        bind-interfaces = true;

        # Wildcard override for your cluster domain
        address = [
          "/${cfg.full_hostname}/${cfg.node_master_ip}"
        ];

        # Optional: forward everything else to your pfSense/router
        server = ["127.0.0.1" "${cfg.nameserver_ip}"];
      };
    };

    #######################################################
    # k3s setup
    #######################################################
    services.k3s = {
      enable = true;
      role = "server";

      # Initialize embedded etcd for single node; you can add agents/servers later.
      clusterInit = true;

      # k3s args to align with your expectations
      extraFlags = [
        # Disable built-in Traefik (we use ingress-nginx)
        "--disable=traefik"
        # Disable built-in k3s load balancer (klipper)
        "--disable=servicelb"
        # Bind API to your chosen port/IP and add SANs for hostname + IP
        "--https-listen-port=${toString cfg.api_server_port}"
        "--advertise-address=${cfg.node_master_ip}"
        "--node-ip=${cfg.node_master_ip}"
        "--tls-san=${cfg.full_hostname}"
        "--tls-san=${cfg.node_master_ip}"

        # Keep kubelet from failing due to swap
        "--kubelet-arg=fail-swap-on=false"

        # Optional: if you want CoreDNS/kube-proxy untouched, leave defaults.
        # You can add more args here as needed (cluster-cidr, service-cidr, etc.).
      ];
    };

    systemd.tmpfiles.rules = [
      # Ingress
      "L+ /var/lib/rancher/k3s/server/manifests/ingress-nginx.yaml - - - - ${ingressHelmChart}"

      # cert-manager
      "L+ /var/lib/rancher/k3s/server/manifests/cert-manager-namespace.yaml - - - - ${certManagerNamespace}"
      "L+ /var/lib/rancher/k3s/server/manifests/cert-manager.yaml - - - - ${certManagerHelmChart}"
      "L+ /var/lib/rancher/k3s/server/manifests/cert-manager-issuers.yaml - - - - ${certManagerIssuers}"

      # MetalLB
      "L+ /var/lib/rancher/k3s/server/manifests/00-metallb-namespace.yaml - - - - ${metallbNamespace}"
      "L+ /var/lib/rancher/k3s/server/manifests/10-metallb-helmchart.yaml - - - - ${metallbHelmChart}"
      "L+ /var/lib/rancher/k3s/server/manifests/20-metallb-address-pool.yaml - - - - ${metallbPool}"

      # Cloudnative Postgres
      "L+ /var/lib/rancher/k3s/server/manifests/00-postgres-cloud-native-namespace.yaml - - - - ${postgresCloudNativeNamespace}"
      "L+ /var/lib/rancher/k3s/server/manifests/10-postgres-cloud-native-helmchart.yaml - - - - ${postgresCloudNativeHelmChart}"
    ];

    # Tip for future multi-node:
    # - Join agents with:
    #   curl -sfL https://get.k3s.io | K3S_URL=https://<server_ip>:${toString cfg.api_server_port} \
    #     K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token) sh -
  };
}
