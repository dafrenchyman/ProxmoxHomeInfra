{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.audiobookshelf;
  parent = config.extraServices.single_node_k3s;

  # --- cert-manager Certificate (for nginx ingress TLS) ---
  audiobookshelfCert = pkgs.writeText "20-audiobookshelf-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: audiobookshelf-tls
      namespace: default
    spec:
      secretName: audiobookshelf-tls-secret
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

  # --- HelmChart (k3s helm-controller) using bjw-s/app-template ---
  audiobookshelfHelmChart = pkgs.writeText "10-audiobookshelf-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: audiobookshelf
      namespace: kube-system
    spec:
      repo: https://bjw-s-labs.github.io/helm-charts/
      chart: app-template
      version: ${cfg.app_template_version}
      targetNamespace: default
      valuesContent: |
        controllers:
          main:
            type: deployment
            strategy: Recreate
            containers:
              app:
                image:
                  repository: ${cfg.image_repository}
                  tag: ${cfg.image_tag}
                  pullPolicy: IfNotPresent
                env:
                  - name: TZ
                    value: "${config.time.timeZone}"

        service:
          main:
            controller: main
            ports:
              http:
                port: 80

        persistence:
          config:
            enabled: true
            type: hostPath
            hostPath: "${cfg.config_path}"
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /config
                    readOnly: false

          metadata:
            enabled: true
            type: hostPath
            hostPath: "${cfg.metadata_path}"
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /metadata
                    readOnly: false

          audiobooks:
            enabled: true
            type: hostPath
            hostPath: "${cfg.audiobooks_path}"
            hostPathType: DirectoryOrCreate
            globalMounts:
              - path: /audiobooks
                readOnly: ${lib.boolToString cfg.media_readonly}

          podcasts:
            enabled: true
            type: hostPath
            hostPath: "${cfg.podcasts_path}"
            hostPathType: DirectoryOrCreate
            globalMounts:
              - path: /podcasts
                readOnly: ${lib.boolToString cfg.media_readonly}

        podSecurityContext:
          fsGroup: ${toString cfg.gid}
        securityContext:
          runAsUser: ${toString cfg.uid}
          runAsGroup: ${toString cfg.gid}

        ingress:
          main:
            enabled: true
            className: nginx
            annotations:
              nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
              nginx.ingress.kubernetes.io/ssl-redirect: "false"
              # homepage auto discovery (optional)
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Media
              gethomepage.dev/name: Audiobookshelf
              gethomepage.dev/description: Audiobooks & Podcasts
              gethomepage.dev/icon: audiobookshelf.png
              gethomepage.dev/siteMonitor: http://audiobookshelf.default.svc.cluster.local:80

            hosts:
              - host: ${cfg.subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    pathType: Prefix
                    service:
                      identifier: main
                      port: http
              - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    pathType: Prefix
                    service:
                      identifier: main
                      port: http
            tls:
              - secretName: audiobookshelf-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.audiobookshelf = {
    enable = lib.mkEnableOption "Audiobookshelf Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "audiobookshelf";
      example = "audiobookshelf";
      description = "Subdomain prefix used for the Audiobookshelf ingress (e.g. audiobookshelf.example.com).";
    };

    # Chart + image controls (handy when you want to bump versions)
    app_template_version = lib.mkOption {
      type = lib.types.str;
      default = "4.3.0";
      example = "4.3.0";
      description = "bjw-s/app-template chart version.";
    };

    image_repository = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/advplyr/audiobookshelf";
      example = "ghcr.io/advplyr/audiobookshelf";
      description = "Container image repository.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "2.32.1";
      example = "2.32.1";
      description = "Container image tag.";
    };

    # Persistence
    config_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/audiobookshelf-config";
      example = "/mnt/kube/config/audiobookshelf-config";
      description = "Path where Audiobookshelf config will be stored (mounted to /config).";
    };

    metadata_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/audiobookshelf-metadata";
      example = "/mnt/kube/config/audiobookshelf-metadata";
      description = "Path where Audiobookshelf metadata will be stored (mounted to /metadata).";
    };

    audiobooks_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/audiobooks";
      example = "/mnt/kube/data/audiobooks";
      description = "Path containing your audiobooks (mounted to /audiobooks).";
    };

    podcasts_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/podcasts";
      example = "/mnt/kube/data/podcasts";
      description = "Path containing your podcasts (mounted to /podcasts).";
    };

    media_readonly = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = true;
      description = "Mount audiobooks/podcasts as read-only inside the container.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "User id that accesses the mounted folders.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "Group id that accesses the mounted folders.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        # k3s installs anything in this directory as an AddOn manifest :contentReference[oaicite:6]{index=6}
        "L+ /var/lib/rancher/k3s/server/manifests/10-audiobookshelf-helmchart.yaml - - - - ${audiobookshelfHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-audiobookshelf-cert.yaml - - - - ${audiobookshelfCert}"

        "d ${cfg.config_path}    0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.metadata_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.audiobooks_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.podcasts_path}   0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })

    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-audiobookshelf-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-audiobookshelf-cert.yaml"
      ];
    })
  ];
}
