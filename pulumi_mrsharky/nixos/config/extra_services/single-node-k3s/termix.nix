{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.termix;
  parent = config.extraServices.single_node_k3s;

  # Build the hosts.json payload that Termix can import (Settings → Import/Export).
  hostsJson = builtins.toJSON {hosts = cfg.sshHosts;};

  # Secret with hosts.json (safer than ConfigMap if you include creds/keys)
  termixImportSecret = pkgs.writeText "00-termix-import-secret.yaml" ''
    apiVersion: v1
    kind: Secret
    metadata:
      name: termix-import
      namespace: default
    type: Opaque
    stringData:
      hosts.json: |
        ${hostsJson}
  '';

  # PV/PVC to persist /app/data (users, hosts, settings)
  termixPVs = pkgs.writeText "00-termix-pvs.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: termix-config-pv
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
      name: termix-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: termix-config-pv
  '';

  # Helm deployment via bjw-s/app-template
  termixHelmChart = pkgs.writeText "10-termix-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: termix
      namespace: kube-system
    spec:
      repo: http://charts.mrsharky.com
      chart: termix
      version: 0.1.0
      targetNamespace: default
      valuesContent: |
        controllers:
          main:
            type: deployment
            strategy: Recreate
            containers:
              app:
                image:
                  repository: ghcr.io/lukegus/termix
                  tag: latest
                  pullPolicy: IfNotPresent
                env:
                  - name: TZ
                    value: "${config.time.timeZone}"
                  - name: PORT
                    value: "8080"
                  - name: Enable_SSL
                    value: "false"
        service:
          main:
            controller: main
            ports:
              http:
                port: 8080

        persistence:
          config:
            enabled: true
            type: hostPath
            hostPath: "${cfg.config_path}"
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /app/data
                    readOnly: false
          import:
            enabled: true
            type: secret
            name: termix-import
            defaultMode: 0440
            globalMounts:
              - path: /import
                readOnly: true

        ingress:
          main:
            enabled: true
            className: nginx
            annotations:
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              # homepage auto discovery (optional)
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Tools
              gethomepage.dev/name: Termix
              gethomepage.dev/description: SSH terminal, tunneling, and remote file management
              gethomepage.dev/icon: terminal.png
              gethomepage.dev/siteMonitor: http://termix.default.svc.cluster.local:8080
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
              - secretName: termix-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';

  # TLS cert for Ingress
  termixCert = pkgs.writeText "20-termix-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: termix-tls
      namespace: default
    spec:
      secretName: termix-tls-secret
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
  options.extraServices.single_node_k3s.termix = {
    enable = lib.mkEnableOption "Termix web SSH client";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "termix";
      example = "termix";
      description = "Subdomain for the Termix ingress (e.g., termix.example.com).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/termix";
      example = "/mnt/kube/config/termix";
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

    # Hosts to pre-provision (import via UI: Settings → Import/Export → /import/hosts.json)
    sshHosts = lib.mkOption {
      description = ''
        Array of Termix host objects to include in hosts.json.
        These are mounted at /import/hosts.json (Secret). Import from the UI.
      '';
      default = [];
      type = lib.types.listOf (lib.types.submodule ({...}: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            example = "web-prod";
            description = "Display name in Termix.";
          };
          ip = lib.mkOption {
            type = lib.types.str;
            example = "192.168.1.50";
          };
          port = lib.mkOption {
            type = lib.types.int;
            default = 22;
            example = 22;
          };
          username = lib.mkOption {
            type = lib.types.str;
            example = "admin";
          };
          authType = lib.mkOption {
            type = lib.types.enum ["password" "key" "credentialId"];
            example = "password";
          };
          # Optional auth fields (depending on authType)
          password = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          key = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Private key PEM for key auth.";
          };
          keyType = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ssh-ed25519";
          };
          credentialId = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          # Optional organization fields
          folder = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "Production";
          };
          tags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
          };
          # Feature flags per host
          pin = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          enableTerminal = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          enableTunnel = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          enableFileManager = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
        };
      }));
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        # Symlinks to k3s manifests
        "L+ /var/lib/rancher/k3s/server/manifests/00-termix-import-secret.yaml - - - - ${termixImportSecret}"
        "L+ /var/lib/rancher/k3s/server/manifests/00-termix-pvs.yaml - - - - ${termixPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-termix-helmchart.yaml - - - - ${termixHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-termix-cert.yaml - - - - ${termixCert}"
        # Ensure config dir exists with correct ownership
        "d ${cfg.config_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })

    (lib.mkIf (!cfg.enable) {
      # Clean up symlinks when disabled
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-termix-import-secret.yaml"
        "r /var/lib/rancher/k3s/server/manifests/00-termix-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-termix-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-termix-cert.yaml"
      ];
    })
  ];
}
