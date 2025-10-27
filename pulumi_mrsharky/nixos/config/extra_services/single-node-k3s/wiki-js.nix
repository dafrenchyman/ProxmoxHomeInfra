{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.wiki_js;
  parent = config.extraServices.single_node_k3s;

  # Cert
  wikiCert = pkgs.writeText "20-wikijs-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: wikijs-tls
      namespace: default
    spec:
      secretName: wikijs-tls-secret
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
  wikiPVs = pkgs.writeText "00-wikijs-pvs.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: wikijs-config-pv
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
      name: wikijs-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: wikijs-config-pv
    ---
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: wikijs-data-pv
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
        path: "${cfg.data_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: wikijs-data-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: wikijs-data-pv
  '';

  # Chart
  wikiHelmChart = pkgs.writeText "10-wikijs-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: wikijs
      namespace: kube-system
    spec:
      repo: https://k8s-at-home.com/charts/
      chart: wikijs
      version: 6.4.2
      targetNamespace: default
      valuesContent: |
        image:
          repository: linuxserver/wikijs
          #tag: version-2.5.219
          tag: v2.5.308-ls194
          pullPolicy: IfNotPresent

        env:
          TZ: "${config.time.timeZone}"
          PUID: "${toString cfg.uid}"
          PGID: "${toString cfg.gid}"
          DB_FILEPATH: "/data/db.sqlite"

        persistence:
          config:
            enabled: true
            type: pvc
            existingClaim: wikijs-config-pvc
            mountPath: /config
            ReadOnly: false
          data:
            enabled: true
            type: pvc
            existingClaim: wikijs-data-pvc
            mountPath: /data
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
              gethomepage.dev/group: Documentation
              gethomepage.dev/name: WikiJS
              gethomepage.dev/description:  Personal Wiki
              gethomepage.dev/icon: wikijs.png
              gethomepage.dev/href: https://${cfg.subdomain}.${parent.full_hostname}/
              gethomepage.dev/siteMonitor: http://wikijs.default.svc.cluster.local:3000
            tls:
              - secretName: wikijs-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
            hosts:
              - host: ${cfg.subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    service:
                      name: wikijs
                      port: 3000
              - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    service:
                      name: wikijs
                      port: 3000
  '';
in {
  options.extraServices.single_node_k3s.wiki_js = {
    enable = lib.mkEnableOption "WikiJS Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "wiki";
      example = "wiki";
      description = "Subdomain prefix used for the WikiJS ingress (e.g. wiki.example.com).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/wikijs";
      default = "/mnt/kube/config/wikijs";
      description = "Path where configuration data will be saved";
    };

    data_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/data/wikijs";
      default = "/mnt/kube/data/wikijs";
      description = "Path where wiki data will be saved";
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
        "L+ /var/lib/rancher/k3s/server/manifests/00-wikijs-pvs.yaml - - - - ${wikiPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-wikijs-helmchart.yaml - - - - ${wikiHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-wikijs-cert.yaml - - - - ${wikiCert}"
        # Create folders and correct permissions
        "d ${cfg.config_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.data_path}    0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        # Remove symbolic links of not enabled
        "r /var/lib/rancher/k3s/server/manifests/00-wikijs-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-wikijs-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-wikijs-cert.yaml"
      ];
    })
  ];
}
