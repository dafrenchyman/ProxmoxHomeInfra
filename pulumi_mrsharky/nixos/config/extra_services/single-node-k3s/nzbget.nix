{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.nzbget;
  parent = config.extraServices.single_node_k3s;

  # Cert
  nzbgetCert = pkgs.writeText "20-nzbget-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: nzbget-tls
      namespace: default
    spec:
      secretName: nzbget-tls-secret
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
  nzbgetPVs = pkgs.writeText "00-nzbget-pvs.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: nzbget-config-pv
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
      name: nzbget-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 1Gi
      volumeName: nzbget-config-pv
    ---
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: nzbget-downloads-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 10Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.download_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: nzbget-downloads-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 10Gi
      volumeName: nzbget-downloads-pv
  '';

  # Chart
  nzbgetHelmChart = pkgs.writeText "10-nzbget-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: nzbget
      namespace: kube-system
    spec:
      repo: https://k8s-at-home.com/charts/
      chart: nzbget
      version: 12.4.2
      targetNamespace: default
      valuesContent: |
        image:
          repository: linuxserver/nzbget
          tag: v25.3-ls215
          pullPolicy: IfNotPresent

        env:
          TZ: "${config.time.timeZone}"
          PUID: "${toString cfg.uid}"
          PGID: "${toString cfg.gid}"
          NZBGET_USER: "${cfg.username}"
          NZBGET_PASS: "${cfg.password}"

        persistence:
          config:
            enabled: true
            type: pvc
            existingClaim: nzbget-config-pvc
            mountPath: /config
            ReadOnly: false
          downloads:
            enabled: true
            type: pvc
            existingClaim: nzbget-downloads-pvc
            mountPath: /downloads
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
              gethomepage.dev/group: Download
              gethomepage.dev/name: NZBget
              gethomepage.dev/description: A self-hosted application designed to manage and access content from Usenet, utilizing NZB files to organize and retrieve binary data.
              gethomepage.dev/icon: nzbget.png
              gethomepage.dev/href: https://${cfg.subdomain}.${parent.full_hostname}
              gethomepage.dev/widget.type: nzbget
              gethomepage.dev/widget.url: http://nzbget.default.svc.cluster.local:6789
              gethomepage.dev/widget.username: ${cfg.username}
              gethomepage.dev/widget.password: ${cfg.password}
              gethomepage.dev/siteMonitor: http://nzbget.default.svc.cluster.local:6789
            tls:
              - secretName: nzbget-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
            hosts:
              - host: ${cfg.subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    service:
                      name: nzbget
                      port: 6789
              - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    service:
                      name: nzbget
                      port: 6789
  '';

  # NZBget Prometheus Exporter Chart
  nzbgetPrometheusExporterHelm = pkgs.writeText "10-nzbget-exporter-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: nzbget-exporter
      namespace: kube-system
    spec:
      repo: http://charts.mrsharky.com
      chart: nzbget-exporter
      version: 0.1.0
      targetNamespace: default
      valuesContent: |
        controllers:
          main:
            type: deployment
            replicas: 1
            strategy: Recreate

            pod:
              annotations:
                prometheus.io/scrape: "true"
                prometheus.io/port: "9452"
                prometheus.io/path: "/metrics"
                prometheus.io/scheme: "http"

            containers:
              app:
                image:
                  repository: ghcr.io/frebib/nzbget-exporter
                  tag: latest
                  pullPolicy: IfNotPresent

                env:
                  - name: NZBGET_HOST
                    value: "http://nzbget.default.svc.cluster.local:6789"
                  - name: NZBGET_USERNAME
                    value: "${cfg.username}"
                  - name: NZBGET_PASSWORD
                    value: "${cfg.password}"
                  - name: TZ
                    value: "America/Los_Angeles"

                ports:
                  - name: web
                    containerPort: 9452
                    protocol: TCP
        service:
          main:
            enabled: true
            controller: main
            # annotations:
            #   prometheus.io/scrape: "true"
            #   prometheus.io/port: "9452"
            #   prometheus.io/path: "/metrics"
            #   prometheus.io/scheme: "http"
            ports:
              http:
                port: 9452
                targetPort: web
                protocol: TCP
  '';

  # NZBget Prometheus Exporter Chart
  dashboardJson = builtins.readFile ./dashboards/nzbget.json;

  # Replace the placeholder wherever it appears (panel.datasource, templating, etc.)
  dashboardJsonFixed = lib.strings.replaceStrings ["\${DS_PROMETHEUS}"] ["prometheus"] dashboardJson;
  nzbgetDashboardConfigMap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "nzbget-dashboard";
      namespace = "default";
      labels.grafana_dashboard = "1";
      annotations.grafana_folder = "Downloads";
    };
    data."nzbget.json" = dashboardJsonFixed;
  };
  cmYaml = lib.generators.toYAML {} nzbgetDashboardConfigMap;
  nzbgetGrafanaDashboard = pkgs.writeText "30-nzbget-grafana-dashboard.yaml" cmYaml;
in {
  options.extraServices.single_node_k3s.nzbget = {
    enable = lib.mkEnableOption "nzbget Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "nzbget";
      example = "nzbget";
      description = "Subdomain prefix used for the nzbget ingress (e.g. nzbget.example.com).";
    };

    username = lib.mkOption {
      type = lib.types.str;
      example = "username";
      default = "nzbget";
      description = "Username";
    };

    password = lib.mkOption {
      type = lib.types.str;
      example = "password";
      default = "nzbget";
      description = "Password";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/nzbget";
      default = "/mnt/kube/config/nzbget";
      description = "Path where configuration data will be saved";
    };

    download_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/data/nzbget_downloads";
      default = "/mnt/kube/data/nzbget_downloads";
      description = "Path where downloads will be saved";
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
        "L+ /var/lib/rancher/k3s/server/manifests/00-nzbget-pvs.yaml - - - - ${nzbgetPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-nzbget-helmchart.yaml - - - - ${nzbgetHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-nzbget-exporter-helmchart.yaml - - - - ${nzbgetPrometheusExporterHelm}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-nzbget-cert.yaml - - - - ${nzbgetCert}"
        "L+ /var/lib/rancher/k3s/server/manifests/30-nzbget-grafana-dashboard.yaml - - - - ${nzbgetGrafanaDashboard}"
        # Create folders and correct permissions
        "d ${cfg.config_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.download_path}    0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        # Remove symbolic links of not enabled
        "r /var/lib/rancher/k3s/server/manifests/00-nzbget-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-nzbget-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-nzbget-cert.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-nzbget-exporter-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/30-nzbget-grafana-dashboard.yaml"
      ];
    })
  ];
}
