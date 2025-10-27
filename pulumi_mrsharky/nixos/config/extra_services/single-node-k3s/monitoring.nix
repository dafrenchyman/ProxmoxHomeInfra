{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.monitoring;
  parent = config.extraServices.single_node_k3s;

  # ---------------------------
  # Certificates
  # ---------------------------
  grafanaCert = pkgs.writeText "20-grafana-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: grafana-tls
      namespace: default
    spec:
      secretName: grafana-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.grafana_subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.grafana_subdomain}.${parent.full_hostname}
        - ${cfg.grafana_subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h
      renewBefore: 360h
  '';

  prometheusCert = pkgs.writeText "20-prometheus-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: prometheus-tls
      namespace: default
    spec:
      secretName: prometheus-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.prometheus_subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.prometheus_subdomain}.${parent.full_hostname}
        - ${cfg.prometheus_subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h
      renewBefore: 360h
  '';

  # ---------------------------
  # PV/PVC (hostPath)
  # ---------------------------
  monitoringPVs = pkgs.writeText "00-monitoring-pvs.yaml" ''
    # Grafana storage
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: grafana-storage-pv
      labels: { type: local }
    spec:
      storageClassName: base
      capacity: { storage: 5Gi }
      accessModes: [ ReadWriteOnce ]
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.grafana_storage_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: grafana-storage-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes: [ ReadWriteOnce ]
      resources:
        requests: { storage: 5Gi }
      volumeName: grafana-storage-pv
    ---
    # Prometheus server data
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: prometheus-server-pv
      labels: { type: local }
    spec:
      storageClassName: base
      capacity: { storage: 10Gi }
      accessModes: [ ReadWriteOnce ]
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.prometheus_data_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: prometheus-server-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes: [ ReadWriteOnce ]
      resources:
        requests: { storage: 10Gi }
      volumeName: prometheus-server-pv
    ---
    # Alertmanager data (optional but handy)
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: alertmanager-data-pv
      labels: { type: local }
    spec:
      storageClassName: base
      capacity: { storage: 2Gi }
      accessModes: [ ReadWriteOnce ]
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.alertmanager_data_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: alertmanager-data-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes: [ ReadWriteOnce ]
      resources:
        requests: { storage: 2Gi }
      volumeName: alertmanager-data-pv
  '';

  # ---------------------------
  # Grafana chart
  # ---------------------------
  grafanaHelmChart = pkgs.writeText "10-grafana-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: grafana
      namespace: kube-system
    spec:
      repo: https://grafana.github.io/helm-charts
      chart: grafana
      version: 10.0.0
      targetNamespace: default
      valuesContent: |
        adminUser: ${cfg.grafana_admin_user}
        adminPassword: ${cfg.grafana_admin_password}

        sidecar:
          dashboards:
            enabled: true
            label: grafana_dashboard              # what label to watch
            folderAnnotation: grafana_folder      # optional: place in folder by annotation
            searchNamespace: ALL                  # or "default"
            provider:
              foldersFromFilesStructure: true

        image:
          # -- The Docker registry
          registry: docker.io
          # -- Docker image repository
          repository: grafana/grafana
          # Overrides the Grafana image tag whose default is the chart appVersion
          tag: "12.1.1"
          # sha: ""
          pullPolicy: IfNotPresent

        persistence:
          enabled: true
          type: pvc
          existingClaim: grafana-storage-pvc

        initChownData:
          enabled: false
        # Pod-wide settings (volumes will be group-owned by 1000 at mount)
        podSecurityContext:
          runAsUser: ${toString cfg.uid}
          runAsGroup: ${toString cfg.gid}
          fsGroup: ${toString cfg.gid}
          fsGroupChangePolicy: "OnRootMismatch"

        # Container user/group
        containerSecurityContext:
          runAsUser: ${toString cfg.uid}
          runAsGroup: ${toString cfg.gid}
          allowPrivilegeEscalation: false

        env:
          GF_SERVER_ROOT_URL: "https://${cfg.grafana_subdomain}.${parent.full_hostname}"

        # Add Prometheus as a default data source (points to the in-cluster service)
        datasources:
          datasources.yaml:
            apiVersion: 1
            datasources:
              - name: Prometheus
                type: prometheus
                uid: prometheus  # Intentionally hard-coding this to a value
                access: proxy
                url: http://prometheus-server.default.svc.cluster.local
                isDefault: true
        service:
          port: 3000
        ingress:
          enabled: true
          ingressClassName: nginx
          annotations:
            kubernetes.io/ingress.class: nginx
            nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
            # homepage auto discovery
            gethomepage.dev/enabled: "true"
            gethomepage.dev/group: Observability
            gethomepage.dev/name: Grafana
            gethomepage.dev/icon: grafana.png
            gethomepage.dev/description: Dashboards
            gethomepage.dev/href: https://${cfg.grafana_subdomain}.${parent.full_hostname}/
            gethomepage.dev/widget.type: grafana
            gethomepage.dev/widget.version: "1"
            gethomepage.dev/widget.alerts: alertmanager
            gethomepage.dev/widget.url: http://grafana.default.svc.cluster.local:3000
            gethomepage.dev/widget.username: ${cfg.grafana_admin_user}
            gethomepage.dev/widget.password: ${cfg.grafana_admin_password}
            gethomepage.dev/siteMonitor: http://grafana.default.svc.cluster.local:3000
            gethomepage.dev/pod-selector: app.kubernetes.io/name=grafana
          hosts:
            - ${cfg.grafana_subdomain}.${parent.full_hostname}
            - ${cfg.grafana_subdomain}.${parent.node_master_ip}.nip.io
          tls:
            - secretName: grafana-tls-secret
              hosts:
                - ${cfg.grafana_subdomain}.${parent.full_hostname}
                - ${cfg.grafana_subdomain}.${parent.node_master_ip}.nip.io
  '';

  # ---------------------------
  # Prometheus chart
  # ---------------------------
  prometheusHelmChart = pkgs.writeText "10-prometheus-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: prometheus
      namespace: kube-system
    spec:
      repo: https://prometheus-community.github.io/helm-charts
      chart: prometheus
      version: 27.39.0
      targetNamespace: default
      valuesContent: |
        alertmanager:
          enabled: true
          persistence:
            enabled: true
            existingClaim: alertmanager-data-pvc
          service:
            port: 9093

        server:
          #extraFlags:
          #  - "--web.enable-lifecycle"
          persistentVolume:
            enabled: true
            existingClaim: prometheus-server-pvc
          podSecurityContext:
            fsGroup: ${toString cfg.gid}
          securityContext:
            runAsUser: ${toString cfg.uid}
            runAsGroup: ${toString cfg.gid}
          service:
            # type: ClusterIP
            port: 9090
          ingress:
            enabled: true
            ingressClassName: nginx
            annotations:
              kubernetes.io/ingress.class: nginx
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              # homepage auto discovery
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Observability
              gethomepage.dev/name: Prometheus
              gethomepage.dev/icon: prometheus.png
              gethomepage.dev/description: Metrics
              gethomepage.dev/href: https://${cfg.prometheus_subdomain}.${parent.full_hostname}/
              gethomepage.dev/siteMonitor: http://prometheus-server.default.svc.cluster.local:9090
              gethomepage.dev/pod-selector: app.kubernetes.io/name=prometheus
            hosts:
              - ${cfg.prometheus_subdomain}.${parent.full_hostname}
              - ${cfg.prometheus_subdomain}.${parent.node_master_ip}.nip.io
            tls:
              - secretName: prometheus-tls-secret
                hosts:
                  - ${cfg.prometheus_subdomain}.${parent.full_hostname}
                  - ${cfg.prometheus_subdomain}.${parent.node_master_ip}.nip.io

        pushgateway:
          enabled: false
  '';
in {
  options.extraServices.single_node_k3s.monitoring = {
    enable = lib.mkEnableOption "Prometheus + Grafana monitoring stack";

    # Grafana
    grafana_subdomain = lib.mkOption {
      type = lib.types.str;
      default = "grafana";
      description = "Subdomain for Grafana ingress.";
    };
    grafana_storage_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/grafana";
      description = "Host path for Grafana persistent storage.";
    };
    grafana_admin_user = lib.mkOption {
      type = lib.types.str;
      example = "admin";
      default = "admin";
      description = "Grafana admin username.";
    };
    grafana_admin_password = lib.mkOption {
      type = lib.types.str;
      example = "admin";
      default = "admin";
      description = "Grafana admin password.";
    };

    # Prometheus
    prometheus_subdomain = lib.mkOption {
      type = lib.types.str;
      default = "prometheus";
      description = "Subdomain for Prometheus ingress.";
    };
    prometheus_data_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/prometheus";
      description = "Host path for Prometheus TSDB storage.";
    };
    alertmanager_data_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/alertmanager";
      description = "Host path for Alertmanager state.";
    };

    # File ownership for created host paths
    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "UID for directory ownership on host paths.";
    };
    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "GID for directory ownership on host paths.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        # Symlink the manifests so k3s picks them up
        "L+ /var/lib/rancher/k3s/server/manifests/00-monitoring-pvs.yaml - - - - ${monitoringPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-grafana-helmchart.yaml - - - - ${grafanaHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-prometheus-helmchart.yaml - - - - ${prometheusHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-grafana-cert.yaml - - - - ${grafanaCert}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-prometheus-cert.yaml - - - - ${prometheusCert}"

        # Ensure host paths exist (owned by your chosen uid/gid)
        "d ${cfg.grafana_storage_path}     0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.prometheus_data_path}     0775 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.alertmanager_data_path}   0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        # Remove the symlinks when disabled
        "r /var/lib/rancher/k3s/server/manifests/00-monitoring-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-grafana-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-prometheus-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-grafana-cert.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-prometheus-cert.yaml"
      ];
    })
  ];
}
