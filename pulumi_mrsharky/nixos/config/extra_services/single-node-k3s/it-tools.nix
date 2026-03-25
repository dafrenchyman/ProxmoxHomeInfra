{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.it_tools;
  parent = config.extraServices.single_node_k3s;

  itToolsCert = pkgs.writeText "20-it-tools-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: it-tools-tls
      namespace: default
    spec:
      secretName: it-tools-tls-secret
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

  itToolsHelmChart = pkgs.writeText "10-it-tools-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: it-tools
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
                  repository: ghcr.io/sharevb/it-tools
                  tag: ${cfg.image_tag}
                  pullPolicy: IfNotPresent

        service:
          main:
            controller: main
            ports:
              http:
                port: 8080

        ingress:
          main:
            enabled: true
            className: nginx
            annotations:
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Tools
              gethomepage.dev/name: IT-Tools
              gethomepage.dev/description: Handy browser-based tools for developers and IT work.
              gethomepage.dev/icon: it-tools
              gethomepage.dev/siteMonitor: http://it-tools.default.svc.cluster.local:8080
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
              - secretName: it-tools-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.it_tools = {
    enable = lib.mkEnableOption "IT-Tools service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "it-tools";
      example = "tools";
      description = "Subdomain prefix used for the IT-Tools ingress.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "2025.10.19";
      example = "2025.10.19";
      description = "Pinned IT-Tools image tag.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/10-it-tools-helmchart.yaml - - - - ${itToolsHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-it-tools-cert.yaml - - - - ${itToolsCert}"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-it-tools-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-it-tools-cert.yaml"
      ];
    })
  ];
}
