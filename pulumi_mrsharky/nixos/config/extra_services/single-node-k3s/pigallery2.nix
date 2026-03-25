{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.pigallery2;
  parent = config.extraServices.single_node_k3s;

  pigallery2Cert = pkgs.writeText "20-pigallery2-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: pigallery2-tls
      namespace: default
    spec:
      secretName: pigallery2-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.subdomain}.${parent.full_hostname}
        - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h
      renewBefore: 360h
  '';

  pigallery2HelmChart = pkgs.writeText "10-pigallery2-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: pigallery2
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
            strategy: Recreate
            containers:
              app:
                image:
                  repository: bpatrik/pigallery2
                  tag: ${cfg.image_tag}
                  pullPolicy: IfNotPresent
                env:
                  - name: NODE_ENV
                    value: "production"
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
                  - path: /app/data/config
                    readOnly: false
          db:
            enabled: true
            type: hostPath
            hostPath: "${cfg.db_path}"
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /app/data/db
                    readOnly: false
          images:
            enabled: true
            type: hostPath
            hostPath: "${cfg.images_path}"
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /app/data/images
                    readOnly: ${lib.boolToString cfg.images_readonly}
          tmp:
            enabled: true
            type: hostPath
            hostPath: "${cfg.tmp_path}"
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /app/data/tmp
                    readOnly: false
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
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Media - Photos
              gethomepage.dev/name: PiGallery2
              gethomepage.dev/description: A fast directory-first self-hosted photo gallery optimized for low-resource servers.
              gethomepage.dev/icon: pigallery2
              gethomepage.dev/siteMonitor: http://pigallery2.default.svc.cluster.local:80
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
              - secretName: pigallery2-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.pigallery2 = {
    enable = lib.mkEnableOption "PiGallery2 service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "pigallery2";
      example = "photos";
      description = "Subdomain prefix used for the PiGallery2 ingress.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "3.5.2";
      example = "3.5.2";
      description = "Pinned PiGallery2 image tag.";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/pigallery2/config";
      example = "/mnt/kube/config/pigallery2/config";
      description = "Host path mounted to /app/data/config.";
    };

    db_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/pigallery2/db";
      example = "/mnt/kube/config/pigallery2/db";
      description = "Host path mounted to /app/data/db for the default SQLite database.";
    };

    images_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/photos";
      example = "/mnt/kube/data/photos";
      description = "Host path mounted to /app/data/images.";
    };

    tmp_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/pigallery2/tmp";
      example = "/mnt/kube/config/pigallery2/tmp";
      description = "Host path mounted to /app/data/tmp.";
    };

    images_readonly = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = true;
      description = "Mount the image library read-only inside the container.";
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
        "L+ /var/lib/rancher/k3s/server/manifests/10-pigallery2-helmchart.yaml - - - - ${pigallery2HelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-pigallery2-cert.yaml - - - - ${pigallery2Cert}"
        "d ${cfg.config_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.db_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.images_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.tmp_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-pigallery2-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-pigallery2-cert.yaml"
      ];
    })
  ];
}
