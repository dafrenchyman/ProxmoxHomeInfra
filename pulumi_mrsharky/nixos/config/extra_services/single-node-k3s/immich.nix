{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.immich;
  parent = config.extraServices.single_node_k3s;

  # -------------------------
  # PV + PVC for the library
  # -------------------------
  immichLibraryPvPvc = pkgs.writeText "00-immich-library-pv-pvc.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: ${cfg.library_pv_name}
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: ${cfg.library_size}
      accessModes:
        - ReadWriteOnce
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: ${cfg.library_host_path}
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ${cfg.library_pvc_name}
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: ${cfg.library_size}
      volumeName: ${cfg.library_pv_name}
  '';

  # -------------------------
  # Optional cert-manager cert
  # -------------------------
  immichCert = pkgs.writeText "20-immich-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: immich-tls
      namespace: default
    spec:
      secretName: ${cfg.tls_secret_name}
      issuerRef:
        kind: ClusterIssuer
        name: ${cfg.cluster_issuer}
      commonName: ${cfg.subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.subdomain}.${parent.full_hostname}
        - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h    # 90 days
      renewBefore: 360h  # 15 days
  '';

  # -------------------------
  # Database
  # -------------------------
  immichDbSecret = pkgs.writeText "04-immich-db-secret.yaml" ''
    apiVersion: v1
    kind: Secret
    metadata:
      name: immich-db-secret
      namespace: default
    type: Opaque
    stringData:
      host: immich-database-rw
      port: "5432"
      username: immich
      password: ${cfg.db.password}
      dbname: immich
  '';

  immichDatabase = pkgs.writeText "05-immich-postgres.yaml" ''
    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata:
      name: immich-database
      namespace: default
    spec:
      instances: 1
      storage:
        size: 4Gi
      imageName: ghcr.io/tensorchord/cloudnative-vectorchord:16.9-0.4.3
      postgresql:
        shared_preload_libraries:
          - "vchord.so"
      bootstrap:
        initdb:
          database: immich
          owner: immich
          secret:
            name: immich-db-secret
          postInitApplicationSQL:
            # Commands based on: https://immich.app/docs/administration/postgres-standalone/#without-superuser-permission
            - CREATE EXTENSION vchord CASCADE;
            - CREATE EXTENSION earthdistance CASCADE;
  '';

  # -------------------------
  # HelmChart (k3s helm-controller)
  # -------------------------
  immichHelmChart = pkgs.writeText "10-immich-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: immich
      namespace: kube-system
    spec:
      repo: https://immich-app.github.io/immich-charts
      chart: immich
      version: ${cfg.chart_version}
      targetNamespace: default
      valuesContent: |
        # IMPORTANT:
        # Official chart requires:
        # - A pre-created PVC for library (we create PV+PVC via manifest)
        # - External Postgres (VectorChord) and Redis/Valkey
        # Ref: chart README + release notes
        #   :contentReference[oaicite:4]{index=4}

        server:
          ingress:
            main:
              enabled: true
              className: nginx
              annotations:
                nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
                # homepage auto discovery (optional)
                gethomepage.dev/enabled: "true"
                gethomepage.dev/group: Media
                gethomepage.dev/name: Immich
                gethomepage.dev/description: A self-hosted application designed to organize, manage, and stream your personal multimedia content, such as photos, videos, music, and more, while providing features like tagging, categorization, and sharing.
                gethomepage.dev/icon: immich.png
                gethomepage.dev/siteMonitor: http://immich-server.default.svc.cluster.local:2283
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
                - secretName: ${cfg.tls_secret_name}
                  hosts:
                    - ${cfg.subdomain}.${parent.full_hostname}
                    - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
          # Service (Immich default is 2283)
          service:
            main:
              ports:
                http:
                  port: 2283
          controllers:
            main:
              containers:
                main:
                  env:
                    TZ: "${config.time.timeZone}"

                    DB_HOSTNAME:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: host
                    DB_PORT:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: port
                    DB_USERNAME:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: username
                    DB_PASSWORD:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: password
                    DB_DATABASE_NAME:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: dbname
                    DB_VECTOR_EXTENSION: "vectorchord"

                    REDIS_HOSTNAME: "immich-valkey"
                    REDIS_PORT: "6379"

        microservices:
          controllers:
            main:
              containers:
                main:
                  env:
                    TZ: "${config.time.timeZone}"

                    DB_HOSTNAME:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: host
                    DB_PORT:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: port
                    DB_USERNAME:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: username
                    DB_PASSWORD:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: password
                    DB_DATABASE_NAME:
                      valueFrom:
                        secretKeyRef:
                          name: immich-db-secret
                          key: dbname
                    DB_VECTOR_EXTENSION: "vectorchord"

                    REDIS_HOSTNAME: "immich-valkey"
                    REDIS_PORT: "6379"

        # Use the chart-bundled Valkey (Redis replacement) (per release notes)
        valkey:
          enabled: ${
      if cfg.enable_valkey
      then "true"
      else "false"
    }

        immich:
          metrics:
            enabled: true
          # Library PVC required by chart README
          persistence:
            library:
              existingClaim: "${cfg.library_pvc_name}"

          # Image tag pinning (chart README notes it doesn't track every app release)
          image:
            tag: "${cfg.immich_image_tag}"

        # Security context (handy when backing onto hostPath)
        podSecurityContext:
          fsGroup: ${toString cfg.gid}
        securityContext:
          runAsUser: ${toString cfg.uid}
          runAsGroup: ${toString cfg.gid}
  '';
in {
  options.extraServices.single_node_k3s.immich = {
    enable = lib.mkEnableOption "Immich Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "immich";
      example = "photos";
      description = "Subdomain prefix used for ingress (e.g. immich.example.com).";
    };

    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "0.10.3";
      example = "0.10.3";
      description = "Helm chart version from immich-app/immich-charts releases.";
    };

    immich_image_tag = lib.mkOption {
      type = lib.types.str;
      default = "v2.0.0";
      example = "v2.0.0";
      description = "Immich image tag. The chart recommends you set this explicitly.";
    };

    # Library storage on the node
    library_host_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/immich/library";
      example = "/mnt/kube/data/immich/library";
      description = "Host path where the Immich library will be stored (hostPath PV).";
    };

    library_size = lib.mkOption {
      type = lib.types.str;
      default = "30Gi";
      example = "2Ti";
      description = "Requested size for the library PVC.";
    };

    library_pv_name = lib.mkOption {
      type = lib.types.str;
      default = "immich-library-pv";
      description = "Name of the PV backing the library.";
    };

    library_pvc_name = lib.mkOption {
      type = lib.types.str;
      default = "immich-library-pvc";
      description = "Name of the PVC used by the chart for the library volume.";
    };

    # DB (external)
    db = {
      host = lib.mkOption {
        type = lib.types.str;
        example = "postgresql.immich.svc.cluster.local";
        default = "postgresql.immich.svc.cluster.local";
        description = "Postgres hostname (must include VectorChord per Immich chart guidance).";
      };
      password = lib.mkOption {
        type = lib.types.str;
        default = "CHANGE_ME";
        description = "Postgres password (consider switching this to a Secret later).";
      };
      vector_extension = lib.mkOption {
        type = lib.types.enum ["vectorchord" "pgvector" "pgvecto.rs"];
        default = "vectorchord";
        description = "DB_VECTOR_EXTENSION (Immich supports these).";
      };
    };

    # Redis/Valkey
    enable_valkey = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable chart-bundled Valkey (Redis replacement).";
    };

    redis = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "redis";
        description = "External Redis hostname (only used if enable_valkey=false).";
      };
      port = lib.mkOption {
        type = lib.types.int;
        default = 6379;
        description = "External Redis port (only used if enable_valkey=false).";
      };
    };

    # UID/GID for hostPath friendliness
    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "runAsUser";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "runAsGroup / fsGroup";
    };

    # TLS (optional)
    cluster_issuer = lib.mkOption {
      type = lib.types.str;
      default = "ca-cluster-issuer";
      description = "cert-manager ClusterIssuer name.";
    };

    tls_secret_name = lib.mkOption {
      type = lib.types.str;
      default = "immich-tls-secret";
      description = "Secret name for TLS cert.";
    };

    create_certificate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create cert-manager Certificate for HTTPS ingress.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        # Namespace (k3s will create namespace when applying chart, but PV/PVC needs it too)
        # You can also pre-create ns via another manifest if you prefer.

        # PV/PVC + chart
        "L+ /var/lib/rancher/k3s/server/manifests/00-immich-library-pv-pvc.yaml - - - - ${immichLibraryPvPvc}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-immich-helmchart.yaml - - - - ${immichHelmChart}"

        # Postgres
        "L+ /var/lib/rancher/k3s/server/manifests/04-immich-db-secret.yaml - - - - ${immichDbSecret}"
        "L+ /var/lib/rancher/k3s/server/manifests/05-immich-postgres.yaml - - - - ${immichDatabase}"

        # Optional TLS cert
        (
          lib.optionalString cfg.create_certificate
          "L+ /var/lib/rancher/k3s/server/manifests/20-immich-cert.yaml - - - - ${immichCert}"
        )

        # Ensure hostPath exists and is writable
        "d ${cfg.library_host_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })

    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-immich-library-pv-pvc.yaml"
        "r /var/lib/rancher/k3s/server/manifests/04-immich-db-secret.yaml"
        "r /var/lib/rancher/k3s/server/manifests/05-immich-postgres.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-immich-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-immich-cert.yaml"
      ];
    })
  ];
}
