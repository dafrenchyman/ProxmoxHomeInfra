{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.airsonic;
  parent = config.extraServices.single_node_k3s;

  # Cert
  airsonicCert = pkgs.writeText "20-airsonic-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: airsonic-tls
      namespace: default
    spec:
      secretName: airsonic-tls-secret
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

  # Volume Mounts
  airsonicPVs = pkgs.writeText "00-airsonic-pvs.yaml" ''
    # #####################
    # Config Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: airsonic-config-pv
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
      name: airsonic-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: airsonic-config-pv
    ---
    # #####################
    # Music Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: airsonic-music-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 1Gi
      accessModes:
        - ReadOnlyMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.music_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: airsonic-music-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadOnlyMany
      resources:
        requests:
          storage: 1Gi
      volumeName: airsonic-music-pv
    ---
    # #####################
    # Transcoding Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: airsonic-transcoding-pv
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
      name: airsonic-transcoding-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 5Gi
      volumeName: airsonic-transcoding-pv
  '';

  # Chart
  airsonicHelmChart = pkgs.writeText "10-airsonic-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: airsonic
      namespace: kube-system
    spec:
      repo: https://k8s-at-home.com/charts/
      chart: airsonic
      version: 6.4.2
      targetNamespace: default
      valuesContent: |
        image:
          repository: lscr.io/linuxserver/airsonic-advanced
          tag: 11.1.4-ls157
          pullPolicy: IfNotPresent

        env:
          TZ: "${config.time.timeZone}"
          PUID: "${toString cfg.uid}"
          PGID: "${toString cfg.gid}"
          JAVA_OPTS: "-Xmx2048m"

        persistence:
          config:
            enabled: true
            type: pvc
            existingClaim: airsonic-config-pvc
            mountPath: /config
            ReadOnly: false
          music:
            enabled: true
            type: pvc
            existingClaim: airsonic-music-pvc
            mountPath: /music
            ReadOnly: true
          transcoding:
            enabled: true
            type: pvc
            existingClaim: airsonic-transcoding-pvc
            mountPath: /config/transcode
            ReadOnly: false

        ingress:
          main:
            enabled: true
            ingressClassName: nginx
            annotations:
              kubernetes.io/ingress.class: nginx
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              # homepage auto discovery
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Media
              gethomepage.dev/name: Airsonic Advanced
              gethomepage.dev/description:  Web-based media streaming server
              gethomepage.dev/icon: airsonic.png
              gethomepage.dev/href: https://${cfg.subdomain}.${parent.full_hostname}/
              gethomepage.dev/siteMonitor: http://airsonic.default.svc.cluster.local:4040
            tls:
              - secretName: airsonic-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
            hosts:
              - host: ${cfg.subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    service:
                      name: airsonic
                      port: 4040
              - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    service:
                      name: airsonic
                      port: 4040
  '';
in {
  options.extraServices.single_node_k3s.airsonic = {
    enable = lib.mkEnableOption "Airsonic Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "airsonic";
      example = "airsonic";
      description = "Subdomain prefix used for the Ainrsonic ingress (e.g. airsonic.example.com).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/airsonic";
      default = "/mnt/kube/config/airsonic";
      description = "Path where configuration data will be saved";
    };

    music_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/data/airsonic";
      default = "/mnt/kube/data/airsonic";
      description = "Path where Airsonic data will be saved";
    };

    transcoding_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/data/airsonic_transcoding";
      default = "/mnt/kube/data/airsonic_transcoding";
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
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/00-airsonic-pvs.yaml - - - - ${airsonicPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-airsonic-helmchart.yaml - - - - ${airsonicHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-airsonic-cert.yaml - - - - ${airsonicCert}"
        "d ${cfg.config_path}      0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.transcoding_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.music_path}       0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-airsonic-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-airsonic-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-airsonic-cert.yaml"
      ];
    })
  ];
}
