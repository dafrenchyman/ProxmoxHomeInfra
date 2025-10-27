{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.plex;
  parent = config.extraServices.single_node_k3s;

  # Volume Mounts
  plexPVs = pkgs.writeText "00-plex-pvs.yaml" ''
    # #####################
    # Config Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: plex-config-pv
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
        path: "${cfg.config_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: plex-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: plex-config-pv
    ---
    # #####################
    # Transcoding Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: plex-transcode-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 5Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.transcoding_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: plex-transcode-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 5Gi
      volumeName: plex-transcode-pv
    ---
    # #####################
    # GPU Transcoding Access
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: plex-gpu-transcoding-pv
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
        path: "/dev/dri/"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: plex-gpu-transcoding-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: plex-gpu-transcoding-pv
  '';

  # Fixed persistence
  basePersistence = {
    config = {
      enabled = true;
      type = "pvc";
      existingClaim = "plex-config-pvc";
      mountPath = "/config";
      readOnly = false;
    };
    transcode = {
      enabled = true;
      type = "pvc";
      existingClaim = "plex-gpu-transcoding-pvc";
      mountPath = "/dev/dri/";
      readOnly = false;
    };
    gpu = {
      enabled = true;
      type = "pvc";
      existingClaim = "plex-transcode-pvc";
      mountPath = "/transcode";
      readOnly = false;
    };
  };

  # Helper method to indent strings
  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    # prefix first line, and after every newline
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  # Helper method to make PV and PVC
  mkPvBlock = v: ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: ${v.name}-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: ${toString v.sizeGi}Gi
      accessModes:
        - ReadOnlyMany
      persistentVolumeReclaimPolicy: "Retain"
      hostPath:
        path: "${v.path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ${v.name}-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadOnlyMany
      resources:
        requests:
          storage: ${toString v.sizeGi}Gi
      volumeName: ${v.name}-pv
    ---
  '';

  # One file that contains ALL PV/PVCs (multi-doc YAML)
  plexContentPvsYaml = lib.concatMapStrings mkPvBlock cfg.extraVolumes;
  plexContentPvsFile = pkgs.writeText "00-plex-content-pvs.yaml" plexContentPvsYaml;

  # Persistence for chart
  extraPersistence = builtins.listToAttrs (map (v: {
      name = v.name;
      value = {
        enabled = true;
        type = "pvc";
        existingClaim = "${v.name}-pvc";
        mountPath = v.mountPath;
        readOnly = true;
      };
    })
    cfg.extraVolumes);

  # Merge fixed + extras; extras override if same key
  persistenceAttrs = basePersistence // extraPersistence;

  # Render *only the map under `persistence:`* as YAML
  persistenceMapYAML = lib.generators.toYAML {} persistenceAttrs;

  # Cert
  plexCert = pkgs.writeText "20-plex-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: plex-tls
      namespace: default
    spec:
      secretName: plex-tls-secret
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

  # Chart
  plexHelmChart = pkgs.writeText "10-plex-helmchart.yaml" ''
        apiVersion: helm.cattle.io/v1
        kind: HelmChart
        metadata:
          name: plex
          namespace: kube-system
        spec:
          repo: https://k8s-at-home.com/charts/
          chart: plex
          version: 6.4.3
          targetNamespace: default
          valuesContent: |
            image:
              repository: lscr.io/linuxserver/plex
              tag: 1.42.2.10156-f737b826c-ls281
              pullPolicy: IfNotPresent

            env:
              TZ: "${config.time.timeZone}"
              PUID: "${toString cfg.uid}"
              PGID: "${toString cfg.gid}"
              PLEX_UID: "${toString cfg.uid}"
              PLEX_GID: "${toString cfg.gid}"
              ALLOWED_NETWORKS: "192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
              # Multiple Plex instances may require a claim from (https://account.plex.tv/claim)
              ${
      if cfg.plex_claim != null
      then ''PLEX_CLAIM: "${cfg.plex_claim}"''
      else ""
    }

            hostNetwork: true
            dnsPolicy: "ClusterFirstWithHostNet"

            service:
              main:
                enabled: true
                ports:
                  http:
                    # 32400/tcp
                    enabled: true
                    servicePort: 32400
                    nodePort: 32400
                    targetPort: 32400
                    protocol: "TCP"
                  # 1900/udp
                  dlna-1:
                    enabled: true
                    port: 1900
                    nodePort: 1900
                    targetPort: 1900
                    protocol: "UDP"
                  # 5353/udp
                  bonjour:
                    enabled: true
                    port: 5353
                    nodePort: 5353
                    targetPort: 5353
                    protocol: "UDP"
                  # 8324/tcp
                  roku:
                    enabled: true
                    port: 8324
                    nodePort: 8324
                    targetPort: 8324
                    protocol: "TCP"
                  # 32410/udp
                  gdm-discovery-1:
                    enabled: true
                    port: 32410
                    nodePort: 32410
                    targetPort: 32410
                    protocol: "UDP"
                  # 32412/udp
                  gdm-discovery-2:
                    enabled: true
                    port: 32412
                    nodePort: 32412
                    targetPort: 32412
                    protocol: "UDP"
                  # 32413/udp
                  gdm-discovery-3:
                    enabled: true
                    port: 32413
                    nodePort: 32413
                    targetPort: 32413
                    protocol: "UDP"
                  # 32414/udp
                  gdm-discovery-4:
                    enabled: true
                    port: 32414
                    nodePort: 32414
                    targetPort: 32414
                    protocol: "UDP"
                  # 32469 / tcp
                  dlna-2:
                    enabled: true
                    port: 32469
                    nodePort: 32469
                    targetPort: 32469
                    protocol: "TCP"

            persistence:
    ${indent 10 persistenceMapYAML}

            ingress:
              main:
                enabled: true
                ingressClassName: nginx
                annotations:
                  kubernetes.io/ingress.class: nginx
                  # nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
                  # homepage auto discovery
                  gethomepage.dev/enabled: "true"
                  gethomepage.dev/group: Media
                  gethomepage.dev/name: Plex Media Center
                  gethomepage.dev/description: Stream personal media to any phone, computer, or smart TV.
                  gethomepage.dev/icon: plex.png
                  gethomepage.dev/href: https://${cfg.subdomain}.${parent.full_hostname}
                  gethomepage.dev/widget.type: plex
                  gethomepage.dev/widget.url: http://plex.default.svc.cluster.local:32400
                  gethomepage.dev/widget.key: ${cfg.token}
                  gethomepage.dev/siteMonitor: http://plex.default.svc.cluster.local:32400
                tls:
                - hosts:
                    - ${cfg.subdomain}.${parent.full_hostname}
                    - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                  secretName: plex-tls-secret
                hosts:
                  - host: ${cfg.subdomain}.${parent.full_hostname}
                    paths:
                      - path: /
                        service:
                          name: plex
                          port: 32400
                  - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                    paths:
                      - path: /
                        service:
                          name: plex
                          port: 32400
  '';

  # Prometheus Exporter
  plexExporterChart = pkgs.writeText "10-plex-exporter-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: plex-exporter
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
                prometheus.io/port: "9000"
                prometheus.io/path: "/metrics"
                prometheus.io/scheme: "http"

            containers:
              app:
                image:
                  repository: ghcr.io/jsclayton/prometheus-plex-exporter
                  tag: latest
                  pullPolicy: IfNotPresent

                env:
                  - name: PLEX_SERVER
                    value: "http://plex.default.svc.cluster.local:32400"
                  - name: PLEX_TOKEN
                    value: "${cfg.token}"
                  - name: TZ
                    value: "${config.time.timeZone}"

                ports:
                  - name: metrics
                    containerPort: 9000
                    protocol: TCP

        service:
          main:
            enabled: true
            controller: main
            # annotations:
            #   prometheus.io/scrape: "true"
            #   prometheus.io/port: "9000"
            #   prometheus.io/path: "/metrics"
            #   prometheus.io/scheme: "http"
            ports:
              http:
                port: 9000
                targetPort: metrics
                protocol: TCP
  '';

  # NZBget Prometheus Exporter Chart
  dashboardJson = builtins.readFile ./dashboards/plex.json;

  # Replace the placeholder wherever it appears (panel.datasource, templating, etc.)
  dashboardJsonFixed = lib.strings.replaceStrings ["\${$datasource}"] ["prometheus"] dashboardJson;
  nzbgetDashboardConfigMap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "plex-dashboard";
      namespace = "default";
      labels.grafana_dashboard = "1";
      annotations.grafana_folder = "Media";
    };
    data."plex.json" = dashboardJsonFixed;
  };
  cmYaml = lib.generators.toYAML {} nzbgetDashboardConfigMap;
  plexGrafanaDashboard = pkgs.writeText "30-plex-grafana-dashboard.yaml" cmYaml;
in {
  options.extraServices.single_node_k3s.plex = {
    enable = lib.mkEnableOption "Plex Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "plex";
      example = "plex";
      description = "Subdomain prefix used for the Plex ingress (e.g. plex.example.com).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/plex";
      default = "/mnt/kube/config/plex";
      description = "Path where configuration data will be saved";
    };

    transcoding_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/data/plex_transcoding";
      default = "/mnt/kube/data/plex_transcoding";
      description = "Path where temporary transcoding data will be saved";
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

    plex_claim = lib.mkOption {
      type = lib.types.str;
      default = null;
      example = "claim-xxxxx";
      description = "Plex claim if needed (https://account.plex.tv/claim)";
    };

    token = lib.mkOption {
      type = lib.types.str;
      default = null;
      example = "your-token";
      description = "Client Token";
    };

    extraVolumes = lib.mkOption {
      description = ''
        Extra hostPath-backed volumes to mount into Plex.
        Each item defines a PV/PVC pair and the pod mount.
        NOTE: `name` must be a DNS-1123 label (lowercase, digits, dashes).
      '';
      default = [];
      type = lib.types.listOf (lib.types.submodule ({...}: {
        options = {
          name = lib.mkOption {
            type = lib.types.strMatching "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$";
            example = "plex-movies";
            description = "Base name; will create '<name>-pv' and '<name>-pvc'.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            example = "/mnt/media/Movies";
            description = "Host path on the node (backed by hostPath).";
          };
          mountPath = lib.mkOption {
            type = lib.types.str;
            example = "/data/movies";
            description = "Container mount path.";
          };
          sizeGi = lib.mkOption {
            type = lib.types.int;
            default = 1;
            example = 1000;
            description = "Capacity to write into PV/PVC metadata (Gi).";
          };
          readOnly = lib.mkOption {
            type = lib.types.bool;
            default = true; # make the container mount readOnly by default (safe for libraries)
            description = "Mount readOnly in the pod (independent of PV accessMode).";
          };
        };
      }));
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Firewall rules
      networking.firewall.allowedTCPPorts = [
        1900 # dlna-1
        5353 # bonjour
        8324 # roku
        32400 # http
        32410 # gdm-discovery-1
        32412 # gdm-discovery-2
        32413 # gdm-discovery-3
        32414 # gdm-discovery-4
        32469 # dlna-2
      ];
      networking.firewall.allowedUDPPorts = [
        1900 # dlna-1
        5353 # bonjour
        8324 # roku
        32400 # http
        32410 # gdm-discovery-1
        32412 # gdm-discovery-2
        32413 # gdm-discovery-3
        32414 # gdm-discovery-4
        32469 # dlna-2
      ];

      systemd.tmpfiles.rules =
        [
          # Chart files to automatically pick up
          "L+ /var/lib/rancher/k3s/server/manifests/00-plex-content-pvs.yaml - - - - ${plexContentPvsFile}"
          "L+ /var/lib/rancher/k3s/server/manifests/00-plex-pvs.yaml - - - - ${plexPVs}"
          "L+ /var/lib/rancher/k3s/server/manifests/10-plex-helmchart.yaml - - - - ${plexHelmChart}"
          "L+ /var/lib/rancher/k3s/server/manifests/10-plex-exporter-helmchart.yaml - - - - ${plexExporterChart}"
          "L+ /var/lib/rancher/k3s/server/manifests/20-plex-cert.yaml - - - - ${plexCert}"
          "L+ /var/lib/rancher/k3s/server/manifests/30-plex-grafana-dashboard.yaml - - - - ${plexGrafanaDashboard}"

          # Create folders and correct permissions
          "d ${cfg.config_path}      0755 ${toString cfg.uid} ${toString cfg.gid} -"
          "d ${cfg.transcoding_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        ]
        ++ (map (v: "d ${v.path} 0755 ${toString cfg.uid} ${toString cfg.gid} -") cfg.extraVolumes);
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        # Remove symbolic links of not enabled
        "r /var/lib/rancher/k3s/server/manifests/00-plex-content-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/00-plex-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-plex-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-plex-exporter-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-plex-cert.yaml"
        "r /var/lib/rancher/k3s/server/manifests/30-plex-grafana-dashboard.yaml"
      ];
    })
  ];
}
