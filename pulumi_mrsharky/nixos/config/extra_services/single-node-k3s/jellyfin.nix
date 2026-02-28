{
  config,
  lib,
  pkgs,
  ...
}: let
  # Helper method to indent strings
  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    # prefix first line, and after every newline
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  cfg = config.extraServices.single_node_k3s.jellyfin;
  parent = config.extraServices.single_node_k3s;

  # Cert (cert-manager)
  jellyfinCert = pkgs.writeText "20-jellyfin-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: jellyfin-tls
      namespace: default
    spec:
      secretName: jellyfin-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.subdomain}.${parent.full_hostname}
        - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h    # 90 days
      renewBefore: 360h  # 15 days
  '';

  # PV/PVC to persist /app/data (users, hosts, settings)
  jellyfinPVs = pkgs.writeText "00-jellyfin-pvs.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: jellyfin-config-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 10Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.config_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: jellyfin-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 10Gi
      volumeName: jellyfin-config-pv
  '';

  #
  vaapiSecurityYaml = ''
    capabilities:
      add:
        - "SYS_ADMIN"
      drop:
        - "ALL"
  '';

  vaapiVolumesYaml = ''
    - name: dri
      hostPath:
        path: /dev/dri
  '';
  vaapiVolumeMountsYaml = ''
    - name: dri
      mountPath: /dev/dri
  '';

  # Chart (k3s helm controller)
  jellyfinHelmChart = pkgs.writeText "10-jellyfin-helmchart.yaml" ''
        apiVersion: helm.cattle.io/v1
        kind: HelmChart
        metadata:
          name: jellyfin
          namespace: kube-system
        spec:
          repo: https://jellyfin.github.io/jellyfin-helm
          chart: jellyfin
          version: ${cfg.chart_version}
          targetNamespace: default
          valuesContent: |
            replicaCount: 1

            # Jellyfin uses a SQLite DB in /config by default; Recreate is the safer strategy.
            deploymentStrategy:
              type: Recreate

            image:
              repository: docker.io/jellyfin/jellyfin
              tag: ${lib.escapeShellArg cfg.image_tag}
              pullPolicy: IfNotPresent

            jellyfin:
              enableDLNA: ${lib.boolToString cfg.enable_dlna}
              env:
                - name: TZ
                  value: "${config.time.timeZone}"

            service:
              type: ClusterIP
              port: 8096
              portName: service

            # IMPORTANT:
            # - persistence.config: PVC or emptyDir only (chart does not support hostPath for config)
            # - persistence.media/cache: can be pvc|hostPath|emptyDir
            persistence:
              config:
                enabled: true
                existingClaim: jellyfin-config-pvc
              media:
                enabled: true
                type: hostPath
                hostPath: "${cfg.media_path}"
                accessMode: ReadOnly
                size: ${cfg.media_pvc_size}
                storageClass: "${cfg.media_storage_class}"
              cache:
                enabled: ${lib.boolToString cfg.enable_cache}
                type: ${cfg.cache_type}
                hostPath: "${cfg.cache_path}"
                accessMode: ReadWriteOnce
                size: ${cfg.cache_pvc_size}
                storageClass: "${cfg.cache_storage_class}"

            podSecurityContext:
              fsGroup: ${toString cfg.gid}
            securityContext:
              runAsUser: ${toString cfg.uid}
              runAsGroup: ${toString cfg.gid}
              allowPrivilegeEscalation: false
    ${lib.optionalString cfg.enable_vaapi (indent 10 vaapiSecurityYaml)}

            volumes:
    ${lib.optionalString cfg.enable_vaapi (indent 8 vaapiVolumesYaml)}

            volumeMounts:
    ${lib.optionalString cfg.enable_vaapi (indent 8 vaapiVolumeMountsYaml)}

            ingress:
              enabled: true
              className: nginx
              annotations:
                nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
                # homepage auto discovery (optional)
                gethomepage.dev/enabled: "true"
                gethomepage.dev/group: Media - Video
                gethomepage.dev/name: Jellyfin
                gethomepage.dev/description: Media server for streaming movies, TV, music, and more.
                gethomepage.dev/icon: jellyfin.png
                gethomepage.dev/siteMonitor: http://jellyfin.default.svc.cluster.local:8096
              hosts:
                - host: ${cfg.subdomain}.${parent.full_hostname}
                  paths:
                    - path: /
                      pathType: Prefix
                - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                  paths:
                    - path: /
                      pathType: Prefix
              tls:
                - secretName: jellyfin-tls-secret
                  hosts:
                    - ${cfg.subdomain}.${parent.full_hostname}
                    - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin";
      example = "jellyfin";
      description = "Subdomain prefix used for the Jellyfin ingress (e.g. jellyfin.example.com).";
    };

    # Helm chart controls
    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "2.7.0";
      example = "2.7.0";
      description = "jellyfin/jellyfin chart version from https://jellyfin.github.io/jellyfin-helm.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "2026022305-amd64";
      example = "2026022305-amd64";
      description = "Jellyfin image tag. Empty uses the chart's appVersion.";
    };

    # Media storage (hostPath mounted at /media)
    media_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/media";
      example = "/mnt/kube/data/media";
      description = "Host path containing your media library (mounted to /media).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/jellyfin";
      example = "/mnt/kube/config/jellyfin";
      description = "Host path used to persist /app/data.";
    };

    # Config storage (PVC only, chart limitation)
    config_pvc_size = lib.mkOption {
      type = lib.types.str;
      default = "5Gi";
      example = "10Gi";
      description = "PVC size for Jellyfin config (/config).";
    };

    config_storage_class = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "local-path";
      description = "StorageClass for Jellyfin config PVC. Empty means cluster default.";
    };

    # Optional media PVC settings (unused when media.type=hostPath, but left here if you later switch to PVC)
    media_pvc_size = lib.mkOption {
      type = lib.types.str;
      default = "25Gi";
      example = "200Gi";
      description = "PVC size for media when using persistence.media.type=pvc.";
    };

    media_storage_class = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "local-path";
      description = "StorageClass for media PVC when using persistence.media.type=pvc.";
    };

    # Cache (transcode cache) — optional
    enable_cache = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = "Enable a persistent /cache volume (useful for transcoding).";
    };

    cache_type = lib.mkOption {
      type = lib.types.enum ["pvc" "hostPath" "emptyDir"];
      default = "hostPath";
      example = "pvc";
      description = "Volume type for /cache when enabled.";
    };

    cache_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/cache/jellyfin";
      example = "/mnt/kube/cache/jellyfin";
      description = "Host path for /cache when cache_type=hostPath.";
    };

    cache_pvc_size = lib.mkOption {
      type = lib.types.str;
      default = "10Gi";
      example = "50Gi";
      description = "PVC size for /cache when cache_type=pvc.";
    };

    cache_storage_class = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "local-path";
      description = "StorageClass for cache PVC when cache_type=pvc. Empty means cluster default.";
    };

    enable_dlna = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = "Enable DLNA (requires hostNetwork per chart behavior).";
    };

    enable_vaapi = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = true;
      description = "Mount /dev/dri into the Jellyfin pod for hardware transcoding (VAAPI).";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "User id that accesses host-mounted folders.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "Group id that accesses host-mounted folders.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules =
        [
          "L+ /var/lib/rancher/k3s/server/manifests/00-jellyfin-pvs.yaml - - - - ${jellyfinPVs}"
          l
          "L+ /var/lib/rancher/k3s/server/manifests/10-jellyfin-helmchart.yaml - - - - ${jellyfinHelmChart}"
          "L+ /var/lib/rancher/k3s/server/manifests/20-jellyfin-cert.yaml - - - - ${jellyfinCert}"

          # Only hostPath dirs need creating here. (/config is PVC by chart design.)
          "d ${cfg.config_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
          "d ${cfg.media_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        ]
        ++ lib.optionals (cfg.enable_cache && cfg.cache_type == "hostPath") [
          "d ${cfg.cache_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        ];
    })

    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-jellyfin-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-jellyfin-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-jellyfin-cert.yaml"
      ];
    })
  ];
}
