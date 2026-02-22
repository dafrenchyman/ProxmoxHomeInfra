{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.ubooquity;
  parent = config.extraServices.single_node_k3s;

  # Cert
  ubooquityCert = pkgs.writeText "20-ubooquity-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: ubooquity-tls
      namespace: default
    spec:
      secretName: ubooquity-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.subdomain}.${parent.full_hostname}
        - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
        - ${cfg.admin_subdomain}.${parent.full_hostname}
        - ${cfg.admin_subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h    # 90 days
      renewBefore: 360h  # 15 days before expiration
  '';

  # Volume Mounts
  ubooquityPVs = pkgs.writeText "00-ubooquity-pvs.yaml" ''
    # #####################
    # Config Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: ubooquity-config-pv
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
      name: ubooquity-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: ubooquity-config-pv
    ---
    # #####################
    # Books Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: ubooquity-books-pv
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
        path: "${cfg.books_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ubooquity-books-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadOnlyMany
      resources:
        requests:
          storage: 1Gi
      volumeName: ubooquity-books-pv
    ---
    # #####################
    # Comics Folder
    # #####################
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: ubooquity-comics-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 5Gi
      accessModes:
        - ReadOnlyMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.comics_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ubooquity-comics-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadOnlyMany
      resources:
        requests:
          storage: 5Gi
      volumeName: ubooquity-comics-pv
  '';

  # Chart
  ubooquityHelmChart = pkgs.writeText "10-ubooquity-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: ubooquity
      namespace: kube-system
    spec:
      repo: https://charts.mrsharky.com/
      chart: ubooquity
      version: 0.1.0
      targetNamespace: default
      valuesContent: |
        image:
          repository: lscr.io/linuxserver/ubooquity
          tag: 3.1.0-ls67
          pullPolicy: IfNotPresent
        env:
          TZ: "${config.time.timeZone}"
          PUID: "${toString cfg.uid}"
          PGID: "${toString cfg.gid}"
          MAXMEM: "2048"

        persistence:
          config:
            enabled: true
            type: pvc
            existingClaim: ubooquity-config-pvc
            mountPath: /config
            ReadOnly: false
          books:
            enabled: true
            type: pvc
            existingClaim: ubooquity-books-pvc
            mountPath: /books
            ReadOnly: true
          comics:
            enabled: true
            type: pvc
            existingClaim: ubooquity-comics-pvc
            mountPath: /comics
            ReadOnly: true

        ingress:
          main:
            enabled: true
            ingressClassName: nginx
            annotations:
              kubernetes.io/ingress.class: nginx
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              nginx.ingress.kubernetes.io/app-root: /ubooquity
              # homepage auto discovery
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Media - Books
              gethomepage.dev/name: Ubooquity
              gethomepage.dev/description:  Digital Bookshelf
              gethomepage.dev/icon: ubooquity.png
              gethomepage.dev/href: https://${cfg.subdomain}.${parent.full_hostname}/ubooquity
              gethomepage.dev/siteMonitor: http://ubooquity.default.svc.cluster.local:2202/ubooquity
            tls:
              - secretName: ubooquity-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                  - ${cfg.admin_subdomain}.${parent.full_hostname}
                  - ${cfg.admin_subdomain}.${parent.node_master_ip}.nip.io
            hosts:
              - host: ${cfg.subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    service:
                      name: ubooquity
                      port: 2202
              - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    service:
                      name: ubooquity
                      port: 2202
          admin:
            main:
            enabled: true
            ingressClassName: nginx
            annotations:
              kubernetes.io/ingress.class: nginx
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              nginx.ingress.kubernetes.io/app-root: /ubooquity
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Media - Books
              gethomepage.dev/name: Ubooquity - Administration
              gethomepage.dev/description:  Digital Bookshelf - Admin Portal
              gethomepage.dev/icon: ubooquity.png
              gethomepage.dev/href: https://${cfg.admin_subdomain}.${parent.full_hostname}/ubooquity/admin
              gethomepage.dev/pod-selector: app.kubernetes.io/name=ubooquity
              gethomepage.dev/siteMonitor: http://ubooquity-admin.default.svc.cluster.local:2203/ubooquity
            tls:
              - secretName: ubooquity-tls-secret
                hosts:
                  - ${cfg.admin_subdomain}.${parent.full_hostname}
                  - ${cfg.admin_subdomain}.${parent.node_master_ip}.nip.io
            hosts:
              - host: ${cfg.admin_subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    service:
                      name: ubooquity-admin
                      port: 2203
              - host: ${cfg.admin_subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    service:
                      name: ubooquity-admin
                      port: 2203
  '';
in {
  options.extraServices.single_node_k3s.ubooquity = {
    enable = lib.mkEnableOption "Ubooquity Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "ubooquity";
      example = "ubooquity";
      description = "Subdomain prefix used for the Ubooquity ingress (e.g. ubooquity.example.com).";
    };

    admin_subdomain = lib.mkOption {
      type = lib.types.str;
      default = "ubooquity-admin";
      example = "ubooquity-admin";
      description = "Subdomain prefix used for the Admin Ubooquity ingress (e.g. ubooquity-admin.example.com).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/ubooquity";
      default = "/mnt/kube/config/ubooquity";
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
        "L+ /var/lib/rancher/k3s/server/manifests/00-ubooquity-pvs.yaml - - - - ${ubooquityPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-ubooquity-helmchart.yaml - - - - ${ubooquityHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-ubooquity-cert.yaml - - - - ${ubooquityCert}"
        "d ${cfg.config_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.books_path}   0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.comics_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-ubooquity-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-ubooquity-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-ubooquity-cert.yaml"
      ];
    })
  ];
}
