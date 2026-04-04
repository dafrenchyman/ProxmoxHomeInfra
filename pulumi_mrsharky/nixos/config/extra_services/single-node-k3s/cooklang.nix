{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.cooklang;
  parent = config.extraServices.single_node_k3s;
  cooklangPort = 9080;

  cooklangCert = pkgs.writeText "20-cooklang-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: cooklang-tls
      namespace: default
    spec:
      secretName: cooklang-tls-secret
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

  cooklangHelmChart = pkgs.writeText "10-cooklang-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: cooklang
      namespace: kube-system
    spec:
      repo: https://charts.mrsharky.com
      chart: cooklang
      version: ${cfg.chart_version}
      targetNamespace: default
      valuesContent: |
        controllers:
          main:
            type: deployment
            replicas: ${toString cfg.replicas}
            strategy: Recreate
            containers:
              app:
                image:
                  repository: ghcr.io/cooklang/cookcli
                  tag: ${cfg.image_tag}
                  pullPolicy: IfNotPresent
                ports:
                  - name: web
                    containerPort: ${toString cooklangPort}
                    protocol: TCP

        service:
          main:
            enabled: true
            controller: main
            type: ClusterIP
            ports:
              http:
                port: ${toString cooklangPort}
                targetPort: web
                protocol: TCP

        persistence:
          recipes:
            enabled: true
            type: hostPath
            hostPath: ${cfg.recipes_path}
            hostPathType: DirectoryOrCreate
            mountPath: /recipes

        ingress:
          main:
            enabled: true
            className: nginx
            annotations:
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Home
              gethomepage.dev/name: Cooklang
              gethomepage.dev/description: Self-hosted Cooklang recipe server powered by CookCLI.
              gethomepage.dev/icon: https://cooklang.org/favicon.png
              gethomepage.dev/siteMonitor: http://cooklang.default.svc.cluster.local:${toString cooklangPort}
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
              - secretName: cooklang-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.cooklang = {
    enable = lib.mkEnableOption "Cooklang service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "cooklang";
      example = "recipes";
      description = "Subdomain prefix used for the Cooklang ingress.";
    };

    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "0.1.0";
      description = "Helm chart version for Cooklang.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "0.26.0";
      description = "CookCLI image tag used by the Cooklang chart.";
    };

    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Replica count for the Cooklang deployment.";
    };

    recipes_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/cooklang/recipes";
      description = "Host path containing Cooklang .cook recipe files.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/10-cooklang-helmchart.yaml - - - - ${cooklangHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-cooklang-cert.yaml - - - - ${cooklangCert}"
        "d ${cfg.recipes_path} 0755 root root -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-cooklang-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-cooklang-cert.yaml"
      ];
    })
  ];
}
