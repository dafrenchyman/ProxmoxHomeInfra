{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.komga;
  parent = config.extraServices.single_node_k3s;

  # Cert
  komgaCert = pkgs.writeText "20-komga-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: komga-tls
      namespace: default
    spec:
      secretName: komga-tls-secret
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
  komgaHelmChart = pkgs.writeText "10-komga-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: komga
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
                  repository: gotson/komga
                  tag: latest
                  pullPolicy: IfNotPresent
                env:
                  - name: TZ
                    value: "${config.time.timeZone}"

        service:
          main:
            controller: main
            ports:
              http:
                port: 25600

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

          books:
            enabled: true
            type: hostPath
            hostPath: "${cfg.books_path}"
            hostPathType: DirectoryOrCreate
            globalMounts:
              - path: /data/books
                readOnly: true
          comics:
            enabled: true
            type: hostPath
            hostPath: "${cfg.comics_path}"
            hostPathType: DirectoryOrCreate
            globalMounts:
              - path: /data/comics
                readOnly: true

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
              # homepage auto discovery (optional)
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Media
              gethomepage.dev/name: Komga
              gethomepage.dev/description: E-Book Reader
              gethomepage.dev/icon: komga.png
              gethomepage.dev/siteMonitor: http://komga.default.svc.cluster.local:25600
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
              - secretName: komga-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.komga = {
    enable = lib.mkEnableOption "Komga Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "komga";
      example = "komga";
      description = "Subdomain prefix used for the Ubooquity ingress (e.g. komga.example.com).";
    };

    # Chart + image controls (handy when you want to bump versions)
    app_template_version = lib.mkOption {
      type = lib.types.str;
      default = "4.3.0";
      example = "4.3.0";
      description = "bjw-s/app-template chart version.";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/komga";
      default = "/mnt/kube/config/komga";
      description = "Path where configuration data will be saved";
    };

    books_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/data/books";
      default = "/mnt/kube/data/books";
      description = "Path where books are located";
    };

    comics_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/data/comics";
      default = "/mnt/kube/data/comics";
      description = "Path where comics are located";
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
        "L+ /var/lib/rancher/k3s/server/manifests/10-komga-helmchart.yaml - - - - ${komgaHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-komga-cert.yaml - - - - ${komgaCert}"
        "d ${cfg.config_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.books_path}   0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.comics_path}   0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-komga-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-komga-cert.yaml"
      ];
    })
  ];
}
