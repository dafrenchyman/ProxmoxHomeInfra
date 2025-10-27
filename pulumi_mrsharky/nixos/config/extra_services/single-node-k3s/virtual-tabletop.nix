{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.virtual-tabletop;
  parent = config.extraServices.single_node_k3s;

  # Cert
  virtual-tabletopCert = pkgs.writeText "20-virtual-tabletop-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: virtual-tabletop-tls
      namespace: default
    spec:
      secretName: virtual-tabletop-tls-secret
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
  virtual-tabletopHelmChart = pkgs.writeText "10-virtual-tabletop-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: virtual-tabletop
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
                  repository: arnoldsmith86/virtualtabletop
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
                port: 8272

        persistence:
          config:
            enabled: true
            type: hostPath
            hostPath: "${cfg.config_path}"
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /app/save
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
              # homepage auto discovery (optional)
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Gaming
              gethomepage.dev/name: Virtual Tabletop
              gethomepage.dev/description: Virtual Tabletop platform for creating and playing games
              gethomepage.dev/icon: https://raw.githubusercontent.com/ArnoldSmith86/virtualtabletop/refs/heads/main/assets/branding/favicon-48.png
              gethomepage.dev/siteMonitor: http://virtual-tabletop.default.svc.cluster.local:8272
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
              - secretName: virtual-tabletop-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.virtual-tabletop = {
    enable = lib.mkEnableOption "virtual-tabletop Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "virtual-tabletop";
      example = "virtual-tabletop";
      description = "Subdomain prefix used for the Virtual Tabletop ingress (e.g. virtual-tabletop.example.com).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/virtual-tabletop";
      default = "/mnt/kube/config/virtual-tabletop";
      description = "Path where configuration data will be saved";
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
        "L+ /var/lib/rancher/k3s/server/manifests/10-virtual-tabletop-helmchart.yaml - - - - ${virtual-tabletopHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-virtual-tabletop-cert.yaml - - - - ${virtual-tabletopCert}"
        "d ${cfg.config_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-virtual-tabletop-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-virtual-tabletop-cert.yaml"
      ];
    })
  ];
}
