{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.trilium;
  parent = config.extraServices.single_node_k3s;

  # Volume Mounts
  triliumPVs = pkgs.writeText "00-trilium-pvs.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: trilium-config-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 20Gi
      accessModes:
        - ReadWriteOnce
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.data_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: trilium-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 20Gi
      volumeName: trilium-config-pv
  '';

  # Helm deployment via bjw-s/app-template
  triliumHelmChart = pkgs.writeText "10-trilium-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: trilium
      namespace: kube-system
    spec:
      repo: https://triliumnext.github.io/helm-charts
      chart: trilium
      version: 1.3.0
      targetNamespace: default
      valuesContent: |
        controllers:
          main:
            type: deployment
            strategy: Recreate
            containers:
              trilium:
                image:
                  repository: triliumnext/trilium
                  tag: v0.99.1
                  pullPolicy: IfNotPresent
                env:
                  - name: TRILIUM_GENERAL_INSTANCENAME
                    value: "trilium"
                  - name: USER_UID
                    value: ${toString cfg.uid}
                  - name: USER_GID
                    value: ${toString cfg.gid}
                  - name: TZ
                    value: "${config.time.timeZone}"

                ports:
                  - name: app
                    containerPort: 8080
                    protocol: TCP

                probes:
                  startup:
                    enabled: true
                    custom: true
                    type: TCP
                    spec:
                      initialDelaySeconds: 45  # Time to wait before starting the probe
                      periodSeconds: 10        # How often to perform the probe
                      timeoutSeconds: 5        # Number of seconds after which the probe times out
                      failureThreshold: 10     # Number of times to try the probe before giving up
                      httpGet: &probesPath
                        path: /login
                        port: 8080

        persistence:
          data:
            enabled: true
            type: persistentVolumeClaim
            existingClaim: trilium-config-pvc

        configini:
          general:
            instanceName: trilium
            noAuthentication: true
            noBackup: true
            noDesktopIcon: true
          network:
            port: 8080
            trustedReverseProxy: false

        podSecurityContext:
          fsGroup: ${toString cfg.gid}
        securityContext:
          runAsUser: ${toString cfg.uid}
          runAsGroup: ${toString cfg.gid}

        service:
          main:
            enabled: true
            ports:
              http:
                port: 8080
                targetPort: app
                protocol: TCP
        ingress:
          main:
            enabled: true
            className: nginx
            annotations:
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              # homepage auto discovery (optional)
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Documentation
              gethomepage.dev/name: Trilium
              gethomepage.dev/description: Trilium Notes
              gethomepage.dev/icon: trilium.png
              gethomepage.dev/siteMonitor: http://trilium.default.svc.cluster.local:8080
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
              - secretName: trilium-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';

  # TLS cert for Ingress
  triliumCert = pkgs.writeText "20-trilium-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: trilium-tls
      namespace: default
    spec:
      secretName: trilium-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.subdomain}.${parent.full_hostname}
        - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h   # 90 days
      renewBefore: 360h # 15 days before expiration
  '';
in {
  options.extraServices.single_node_k3s.trilium = {
    enable = lib.mkEnableOption "Termix web SSH client";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "trilium";
      example = "trilium";
      description = "Subdomain for the Termix ingress (e.g., trilium.example.com).";
    };

    data_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/trilium";
      example = "/mnt/kube/data/trilium";
      description = "Host path used to persist /app/data.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "Filesystem owner UID for created data directories.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "Filesystem owner GID for created data directories.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        # Symlinks to k3s manifests
        "L+ /var/lib/rancher/k3s/server/manifests/00-trilium-pvs.yaml - - - - ${triliumPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-trilium-helmchart.yaml - - - - ${triliumHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-trilium-cert.yaml - - - - ${triliumCert}"
        # Ensure config dir exists with correct ownership
        "d ${cfg.data_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })

    (lib.mkIf (!cfg.enable) {
      # Clean up symlinks when disabled
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-trilium-pvs.yaml - - - - ${triliumPVs}"
        "r /var/lib/rancher/k3s/server/manifests/10-trilium-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-trilium-cert.yaml"
      ];
    })
  ];
}
