{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.transmission_openvpn;
  parent = config.extraServices.single_node_k3s;

  #b64 = lib.strings.toBase64;

  # Cert
  transmissionOpenVpnCert = pkgs.writeText "20-transmission-openvpn-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: transmission-openvpn-tls
      namespace: default
    spec:
      secretName: transmission-openvpn-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.subdomain}.${parent.full_hostname}
        - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h    # 90 days
      renewBefore: 360h  # 15 days before expiration
  '';

  # Secret
  transmissionOpenVpnSecrets = pkgs.writeText "00-transmission-openvpn-secrets.yaml" ''
    apiVersion: v1
    kind: Secret
    metadata:
      name: transmission-openvpn-secrets
      labels:
        type: local
    type: Opaque
    stringData:
      username: "${cfg.vpn_username}"
      password: "${cfg.vpn_password}"
  '';

  # Volumes
  transmissionOpenVpnPv = pkgs.writeText "00-transmission-openvpn-pvs.yaml" ''
    # #####################
    # Configuration Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: transmission-openvpn-config-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 1Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.config_folder}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: transmission-openvpn-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: transmission-openvpn-config-pv
    ---

    # #####################
    # Completed Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: transmission-openvpn-completed-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 1Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.completed_folder}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: transmission-openvpn-completed-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: transmission-openvpn-completed-pv
    ---

    # #####################
    # Incomplete Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: transmission-openvpn-incomplete-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 1Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.incomplete_folder}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: transmission-openvpn-incomplete-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: transmission-openvpn-incomplete-pv
    ---

    # #####################
    # Watch Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: transmission-openvpn-watch-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 1Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.watch_folder}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: transmission-openvpn-watch-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: transmission-openvpn-watch-pv

  '';

  # Chart
  transmissionOpenVpnHelmChart = pkgs.writeText "10-transmission-openvpn-chart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: transmission-openvpn
      namespace: kube-system
    spec:
      repo: https://bananaspliff.github.io/geek-charts
      chart: transmission-openvpn
      version: 0.1.0
      targetNamespace: default
      valuesContent: |
        image:
          repository: haugene/transmission-openvpn
          tag: 5.3.2
          pullPolicy: IfNotPresent
        env:
          - name: TZ
            value: "${config.time.timeZone}"
          - name: CREATE_TUN_DEVICE
            value: "true"
          - name: PUID
            value: "${toString cfg.uid}"
          - name: PGID
            value: "${toString cfg.gid}"
          - name: LOCAL_NETWORK
            value: "10.0.0.0/16"
          - name: OPENVPN_PROVIDER
            value: "${cfg.vpn_provider}"
          - name: OPENVPN_CONFIG
            value: "${cfg.vpn_server}"
          - name: OPENVPN_USERNAME
            value: "${cfg.vpn_username}"
          - name: OPENVPN_PASSWORD
            value: "${cfg.vpn_password}"
          - name: OPENVPN_OPTS
            value: "--inactive 3600 --ping 10 --ping-exit 60 --mute-replay-warnings"
          - name: TRANSMISSION_DOWNLOAD_QUEUE_SIZE
            value: "600"
          - name: TRANSMISSION_PREALLOCATION
            value: "0"
          - name: TRANSMISSION_RATIO_LIMIT
            value: "0.25"
          - name: TRANSMISSION_RATIO_LIMIT_ENABLED
            value: "true"
          - name: TRANSMISSION_SPEED_LIMIT_UP
            value: "500"
          - name: TRANSMISSION_SPEED_LIMIT_UP_ENABLED
            value: "true"
          - name: TRANSMISSION_ALT_SPEED_TIME_ENABLED
            value: "true"
          - name: TRANSMISSION_ALT_SPEED_TIME_BEGIN
            value: "420"
          - name: TRANSMISSION_ALT_SPEED_TIME_END
            value: "1320"
          - name: TRANSMISSION_ALT_SPEED_UP
            value: "100"
          - name: TRANSMISSION_ALT_SPEED_DOWN
            value: "100000"
          - name: TRANSMISSION_SEED_QUEUE_SIZE
            value: "10"
          - name: TRANSMISSION_SEED_QUEUE_ENABLED
            value: "true"
          - name: TRANSMISSION_IDLE_SEEDING_LIMIT
            value: "15"
          - name: TRANSMISSION_IDLE_SEEDING_LIMIT_ENABLED
            value: "true"
          - name: WEBPROXY_ENABLED
            value: "false"
        volumes:
          - name: "transmission-openvpn-config"
            persistentVolumeClaim:
              claimName: "transmission-openvpn-config-pvc"
          - name: "transmission-openvpn-watch"
            persistentVolumeClaim:
              claimName: "transmission-openvpn-watch-pvc"
          - name: "transmission-openvpn-completed"
            persistentVolumeClaim:
              claimName: "transmission-openvpn-completed-pvc"
          - name: "transmission-openvpn-incomplete"
            persistentVolumeClaim:
              claimName: "transmission-openvpn-incomplete-pvc"
        volumeMounts:
          - name: transmission-openvpn-config
            mountPath: "/data/transmission-home"
          - name: transmission-openvpn-watch
            mountPath: "/data/watch"
          - name: transmission-openvpn-incomplete
            mountPath: "/data/incomplete"
          - name: transmission-openvpn-completed
            mountPath: "/data/completed"
        service:
          type: ClusterIP
          port: 80
        securityContext:
          privileged: true
          capabilities:
            add:
              - NET_ADMIN
              - MKNOD
  '';

  transmissionOpenVpnIngress = pkgs.writeText "20-transmission-openvpn-ingress.yaml" ''
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: transmission-openvpn-ingress
      namespace: default
      annotations:
        kubernetes.io/ingress.class: nginx
        nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
        # homepage auto discovery
        gethomepage.dev/enabled: "true"
        gethomepage.dev/group: Download
        gethomepage.dev/name: Transmission via OpenVPN
        gethomepage.dev/description: A free, open-source BitTorrent client for downloading large files over peer-to-peer networks, often used for sharing or accessing large media files such as movies and TV shows.
        gethomepage.dev/icon: transmission.png
        gethomepage.dev/href: https://${cfg.subdomain}.${parent.full_hostname}/
        gethomepage.dev/pod-selector: app=transmission-openvpn
        gethomepage.dev/widget.type: transmission
        gethomepage.dev/widget.url: http://transmission-openvpn.default.svc.cluster.local
        gethomepage.dev/widget.username: ${cfg.transmission_username}
        gethomepage.dev/widget.password: ${cfg.transmission_password}
        gethomepage.dev/widget.rpcUrl: /transmission/
        gethomepage.dev/siteMonitor: http://transmission-openvpn.default.svc.cluster.local
    spec:
      ingressClassName: nginx
      tls:
      - secretName: transmission-openvpn-tls-secret
        hosts:
          - ${cfg.subdomain}.${parent.full_hostname}
          - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
      rules:
        - host: ${cfg.subdomain}.${parent.full_hostname}
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: transmission-openvpn
                    port:
                      number: 80
        - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: transmission-openvpn
                    port:
                      number: 80
  '';

  # Prometheus Exporter
  transmissionOpenVpnExporterChart = pkgs.writeText "10-transmission-openvpn-exporter-chart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: transmission-openvpn-exporter
      namespace: kube-system
    spec:
      repo: https://bjw-s-labs.github.io/helm-charts/
      chart: app-template
      version: 4.3.0
      targetNamespace: default
      valuesContent: |
        controllers:
          main:
            type: deployment
            replicas: 1
            strategy: Recreate
            pod:
              annotations:
                prometheus.io/scrape: "true"
                prometheus.io/port: "19091"
                prometheus.io/path: "/metrics"
                prometheus.io/scheme: "http"
            containers:
              app:
                image:
                  repository: metalmatze/transmission-exporter
                  tag: latest
                  pullPolicy: IfNotPresent
                env:
                  - name: WEB_PATH
                    value: "/metrics"
                  - name: WEB_ADDR
                    value: ":19091"
                  - name: TRANSMISSION_ADDR
                    value: "http://transmission-openvpn.default.svc.cluster.local:80"
                  - name: TRANSMISSION_USERNAME
                    value: "${cfg.transmission_username}"
                  - name: TRANSMISSION_PASSWORD
                    value: "${cfg.transmission_password}"
                  - name: TZ
                    value: "${config.time.timeZone}"
                ports:
                  - name: metrics
                    containerPort: 19091
                    protocol: TCP
        service:
          main:
            enabled: true
            controller: main
            # annotations:
            #   prometheus.io/scrape: "true"
            #   prometheus.io/port: "19091"
            #   prometheus.io/path: "/metrics"
            #   prometheus.io/scheme: "http"
            ports:
              http:
                port: 19091
                targetPort: metrics
                protocol: TCP
  '';

  # NZBget Prometheus Exporter Chart
  dashboardJson = builtins.readFile ./dashboards/transmission.json;

  # Replace the placeholder wherever it appears (panel.datasource, templating, etc.)
  dashboardJsonFixed = lib.strings.replaceStrings ["\${DS_PROMETHEUS}"] ["prometheus"] dashboardJson;
  dashboardConfigMap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "transmission-dashboard";
      namespace = "default";
      labels.grafana_dashboard = "1";
      annotations.grafana_folder = "Downloads";
    };
    data."transmission.json" = dashboardJsonFixed;
  };
  cmYaml = lib.generators.toYAML {} dashboardConfigMap;
  grafanaDashboard = pkgs.writeText "30-transmission-openvpn-grafana-dashboard.yaml" cmYaml;
in {
  options.extraServices.single_node_k3s.transmission_openvpn = {
    enable = lib.mkEnableOption "Transmission OpenVPN";

    config_folder = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/transmission_openvpn";
      example = "/mnt/kube/config/transmission_openvpn";
      description = "Folder where to store configuration files";
    };

    watch_folder = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/transmission_openvpn/watch";
      example = "/mnt/kube/data/transmission_openvpn/watch";
      description = "Folder where to watch for new torrents";
    };

    completed_folder = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/transmission_openvpn/completed";
      example = "/mnt/kube/data/transmission_openvpn/completed";
      description = "Folder where to store completed torrent downloads";
    };

    incomplete_folder = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/transmission_openvpn/incomplete";
      example = "/mnt/kube/data/transmission_openvpn/incomplete";
      description = "Folder where to store incomplete torrent downloads";
    };

    transmission_username = lib.mkOption {
      type = lib.types.str;
      example = "transmission";
      default = "transmission";
      description = "Transmission Username";
    };

    transmission_password = lib.mkOption {
      type = lib.types.str;
      example = "password";
      default = "password";
      description = "Transmission Password";
    };

    vpn_provider = lib.mkOption {
      type = lib.types.str;
      example = "PIA";
      description = "VPN Provider";
    };

    vpn_server = lib.mkOption {
      type = lib.types.str;
      example = "ca_vancouver";
      description = "VPN Server";
    };

    vpn_username = lib.mkOption {
      type = lib.types.str;
      example = "user_name";
      description = "VPN Username";
    };

    vpn_password = lib.mkOption {
      type = lib.types.str;
      example = "password123";
      description = "VPN Password";
    };

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "transmission";
      example = "transmission";
      description = "Subdomain prefix used for the Transmission ingress (e.g. transmission.example.com).";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "User id that accesses the mounted folders";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "Group id that accesses the mounted folders";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        # Chart files to automatically pick up
        "L+ /var/lib/rancher/k3s/server/manifests/00-transmission-openvpn-secrets.yaml - - - - ${transmissionOpenVpnSecrets}"
        "L+ /var/lib/rancher/k3s/server/manifests/00-transmission-openvpn-pvs.yaml - - - - ${transmissionOpenVpnPv}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-transmission-openvpn-chart.yaml - - - - ${transmissionOpenVpnHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-transmission-openvpn-exporter-chart.yaml - - - - ${transmissionOpenVpnExporterChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-transmission-openvpn-cert.yaml - - - - ${transmissionOpenVpnCert}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-transmission-openvpn-ingress.yaml - - - - ${transmissionOpenVpnIngress}"
        "L+ /var/lib/rancher/k3s/server/manifests/30-transmission-openvpn-grafana-dashboard.yaml - - - - ${grafanaDashboard}"

        # Create folders and correct permissions
        "d ${cfg.watch_folder}      0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.incomplete_folder} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.completed_folder}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.config_folder}     0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        # Remove symbolic links of not enabled
        "r /var/lib/rancher/k3s/server/manifests/00-transmission-openvpn-secrets.yaml"
        "r /var/lib/rancher/k3s/server/manifests/00-transmission-openvpn-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-transmission-openvpn-chart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-transmission-openvpn-exporter-chart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-transmission-openvpn-cert.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-transmission-openvpn-ingress.yaml"
        "r /var/lib/rancher/k3s/server/manifests/30-transmission-openvpn-grafana-dashboard.yaml"
      ];
    })
  ];
}
