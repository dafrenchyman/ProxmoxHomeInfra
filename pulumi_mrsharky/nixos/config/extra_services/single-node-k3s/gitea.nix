{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.gitea;
  parent = config.extraServices.single_node_k3s;

  # PV/PVC to persist /app/data (users, hosts, settings)
  giteaPVs = pkgs.writeText "00-gitea-pvs.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: gitea-config-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 20Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.config_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: gitea-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 20Gi
      volumeName: gitea-config-pv
  '';

  # gitea admin credentials
  giteaAdminSecret = pkgs.writeText "00-gitea-admin-secret.yaml" ''
    apiVersion: v1
    kind: Secret
    metadata:
      name: gitea-admin-creds
      namespace: default
    type: Opaque
    stringData:
      username: ${cfg.admin_username}
      password: ${cfg.admin_password}
  '';

  # RBAC + ServiceAccount so the Job can patch the ingress and create/update the token Secret
  giteaTokenJobRbac = pkgs.writeText "10-gitea-token-rbac.yaml" ''
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: gitea-token-writer
        namespace: default
    ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: Role
      metadata:
        name: gitea-token-writer
        namespace: default
      rules:
        - apiGroups: [""]
          resources: ["secrets"]
          verbs: ["get","list","create","update","patch","watch","delete"]
        - apiGroups: ["networking.k8s.io"]
          resources: ["ingresses"]
          verbs: ["get","list","patch","update"]
        - apiGroups: ["apps"]
          resources: ["deployments"]
          verbs: ["get","list","watch"]
    ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: RoleBinding
      metadata:
        name: gitea-token-writer
        namespace: default
      subjects:
        - kind: ServiceAccount
          name: gitea-token-writer
          namespace: default
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: Role
        name: gitea-token-writer
  '';

  # Job to create token for homepage
  # NOTE: - This job's sole purpose is to run and generate a token with the gitea admin
  #         user that will automatically be injected into ingress for homepage to be able
  #         to give metrics on it: "gethomepage.dev/widget.key"
  #       - I'm sure this could be improved and permissions could be refined better
  giteaTokenJob = pkgs.writeText "20-gitea-token-job.yaml" ''
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: gitea-homepage-token
      namespace: default
    spec:
      backoffLimit: 3
      template:
        spec:
          serviceAccountName: gitea-token-writer
          restartPolicy: OnFailure
          containers:
          - name: make-token-and-annotate
            image: alpine:3.20
            command: ["/bin/sh","-c"]
            env:
              - name: GITEA_URL
                value: "http://gitea-http.default.svc.cluster.local:3000"
              - name: GITEA_ADMIN_USERNAME
                valueFrom:
                  secretKeyRef: { name: gitea-admin-creds, key: username }
              - name: GITEA_ADMIN_PASSWORD
                valueFrom:
                  secretKeyRef: { name: gitea-admin-creds, key: password }
              - name: TOKEN_SECRET_NAME
                value: "gitea-homepage-token"
              - name: INGRESS_NAME
                value: "gitea"
              - name: INGRESS_NS
                value: "default"
            args:
              - |
                set -euo pipefail
                echo "[init] installing tools..."
                apk add --no-cache curl jq ca-certificates kubectl >/dev/null

                echo "[wait] waiting for $GITEA_URL ..."
                until curl -fsS "$GITEA_URL/api/v1/version" >/dev/null; do sleep 3; done

                # Optional: wait for the gitea deployment to report available
                kubectl -n "$INGRESS_NS" wait --for=condition=available --timeout=180s \
                  deploy -l app.kubernetes.io/name=gitea || true

                # Reuse token if Secret exists
                if kubectl -n "$INGRESS_NS" get secret "$TOKEN_SECRET_NAME" >/dev/null 2>&1; then
                  TOKEN="$(kubectl -n "$INGRESS_NS" get secret "$TOKEN_SECRET_NAME" -o jsonpath='{.data.token}' | base64 -d)"
                else
                  echo "[gitea] checking existing tokens …"
                  EXISTING="$(curl -fsS -u "$GITEA_ADMIN_USERNAME:$GITEA_ADMIN_PASSWORD" \
                    "$GITEA_URL/api/v1/users/$GITEA_ADMIN_USERNAME/tokens" \
                    | jq -r '.[] | select(.name=="homepage-token") | .sha1' || true)"

                  if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
                    TOKEN="$EXISTING"
                  else
                    echo "[gitea] creating token …"
                    CODE="$(curl -sS -u "$GITEA_ADMIN_USERNAME:$GITEA_ADMIN_PASSWORD" \
                      -H 'Content-Type: application/json' \
                      -d '{"name":"homepage-token","scopes":["all"]}' \
                      -o /tmp/body.json -w '%{http_code}' \
                      "$GITEA_URL/api/v1/users/$GITEA_ADMIN_USERNAME/tokens")"
                    if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
                      echo "[error] token create HTTP $CODE"; cat /tmp/body.json; exit 1
                    fi
                    TOKEN="$(jq -r '.sha1' </tmp/body.json)"
                    [ -n "$TOKEN" ] || { echo "[fatal] empty token"; exit 1; }
                  fi

                  kubectl -n "$INGRESS_NS" create secret generic "$TOKEN_SECRET_NAME" \
                    --from-literal=token="$TOKEN" \
                    --dry-run=client -o yaml | kubectl apply -f -
                fi

                echo "[patch] annotating ingress with token …"
                kubectl -n "$INGRESS_NS" annotate ingress "$INGRESS_NAME" \
                  "gethomepage.dev/widget.key=$TOKEN" --overwrite
                echo "[done]"
  '';

  # Helm deployment via bjw-s/app-template
  giteaHelmChart = pkgs.writeText "10-gitea-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: gitea
      namespace: default
    spec:
      repo: https://dl.gitea.com/charts/
      chart: gitea
      version: 12.4.0
      targetNamespace: default
      valuesContent: |
        gitea:
          admin:
            username: ${cfg.admin_username}
            password: ${cfg.admin_password}
            email: "${cfg.admin_email}"
            passwordMode: initialOnlyNoReset
          config:
            database:
              DB_TYPE: postgres
            indexer:
              ISSUE_INDEXER_TYPE: bleve
              REPO_INDEXER_ENABLED: true
            metrics:
              ENABLED: true
              ENABLED_ISSUE_BY_REPOSITORY: true
              ENABLED_ISSUE_BY_LABEL: true
            server:
              # Base URL used in clone URLs etc.
              ROOT_URL: "https://${cfg.subdomain}.${parent.full_hostname}/"

              # Tell Gitea to run its own SSH server in the container
              START_SSH_SERVER: true

              # Pod-internal SSH listen port
              SSH_LISTEN_PORT: 2222

              # The external port clients will use (LoadBalancer below)
              SSH_PORT: 22

              # Hostname clients will see in clone URLs (optional but nice)
              SSH_DOMAIN: "${cfg.ssh_hostname}"

              ENABLE_PPROF: true

          additionalConfigFromEnvs:
            - name: TZ
              value: "${config.time.timeZone}"
          metrics:
            enabled: true
            serviceMonitor:
              enabled: false

        # Bundled Dependencies
        valkey-cluster:
          enabled: false
        valkey:
          enabled: true
        postgresql:
          enabled: true
        postgresql-ha:
          enabled: false
        service:
          http:
            port: 3000
            annotations:
              prometheus.io/scrape: "true"
              prometheus.io/path: "/metrics"
              prometheus.io/port: "3000"
              prometheus.io/scheme: "http"
          ssh:
            type: LoadBalancer
            # Pin the IP if provided; otherwise MetalLB allocates from the pool
            loadBalancerIP: ${cfg.ssh_lb_ip or ""}
            externalTrafficPolicy: Local
            port: 22
            targetPort: 2222
            annotations:
              metallb.universe.tf/address-pool: ${parent.poolName}

        persistence:
          enabled: true
          existingClaim: gitea-config-pvc

        ingress:
          enabled: true
          className: nginx
          annotations:
            nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
            # homepage auto discovery (optional)
            gethomepage.dev/enabled: "true"
            gethomepage.dev/group: Tools
            gethomepage.dev/name: Gitea
            gethomepage.dev/description: Git
            gethomepage.dev/icon: gitea.png
            gethomepage.dev/widget.type: gitea
            gethomepage.dev/widget.url: http://gitea-http.default.svc.cluster.local:3000
            gethomepage.dev/siteMonitor: http://gitea-http.default.svc.cluster.local:3000

          hosts:
            - host: ${cfg.subdomain}.${parent.full_hostname}
              paths:
                - path: /
                  pathType: Prefix
                  service:
                    identifier: http
                    port: http
            - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
              paths:
                - path: /
                  pathType: Prefix
                  service:
                    identifier: http
                    port: http
          tls:
            - secretName: gitea-tls-secret
              hosts:
                - ${cfg.subdomain}.${parent.full_hostname}
                - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';

  # TLS cert for Ingress
  giteaCert = pkgs.writeText "20-gitea-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: gitea-tls
      namespace: default
    spec:
      secretName: gitea-tls-secret
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

  # Gitea Grafana Dashboard
  dashboardJson = builtins.readFile ./dashboards/gitea.json;

  # Replace the placeholder wherever it appears (panel.datasource, templating, etc.)
  dashboardJsonFixed = lib.strings.replaceStrings ["\${DS_PROMETHEUS}"] ["prometheus"] dashboardJson;
  giteaDashboardConfigMap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "gitea-dashboard";
      namespace = "default";
      labels.grafana_dashboard = "1";
      annotations.grafana_folder = "Development";
    };
    data."gitea.json" = dashboardJsonFixed;
  };
  cmYaml = lib.generators.toYAML {} giteaDashboardConfigMap;
  giteaGrafanaDashboard = pkgs.writeText "30-gitea-grafana-dashboard.yaml" cmYaml;
in {
  options.extraServices.single_node_k3s.gitea = {
    enable = lib.mkEnableOption "Gitea git server";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "gitea";
      example = "gitea";
      description = "Subdomain for the Gitea ingress (e.g., gitea.example.com).";
    };

    # SSH hostname used in clone URLs; separate host is recommended
    ssh_hostname = lib.mkOption {
      type = lib.types.str;
      default = "ssh.gitea.${parent.full_hostname}";
      example = "ssh.gitea.example.com";
      description = "Hostname used by Gitea for SSH clone URLs.";
    };

    # Optional: pin a specific MetalLB IP for the SSH LoadBalancer
    ssh_lb_ip = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "192.168.10.51";
      example = "192.168.10.51";
      description = "Static MetalLB IP for the SSH Service.";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/gitea";
      example = "/mnt/kube/config/gitea";
      description = "Host path used to persist /app/data.";
    };

    admin_username = lib.mkOption {
      type = lib.types.str;
      default = "gitea_admin";
      example = "gitea_admin";
      description = "Username for the Gitea admin user";
    };

    admin_email = lib.mkOption {
      type = lib.types.str;
      default = "gitea@${parent.full_hostname}";
      example = "gitea@local.domain";
      description = "Email for the Gitea admin user";
    };

    admin_password = lib.mkOption {
      type = lib.types.str;
      default = "password";
      example = "password";
      description = "Password for the Gitea admin user";
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
      # If you want a DNS name for SSH, add a dnsmasq record when an IP is pinned.
      # (If ssh_lb_ip is null, MetalLB allocates an IP; add DNS later once known.)
      services.dnsmasq.settings.address = lib.mkAfter (
        if cfg.ssh_lb_ip != null
        then ["/${cfg.ssh_hostname}/${cfg.ssh_lb_ip}"]
        else []
      );

      # inside the (lib.mkIf cfg.enable) block of gitea.nix
      # environment.etc."dnsmasq.d/gitea-ssh.conf".text =
      #   if cfg.ssh_lb_ip != null then
      #     "address=/${cfg.ssh_hostname}/${cfg.ssh_lb_ip}\n"
      #   else
      #     "";

      systemd.tmpfiles.rules = [
        # Symlinks to k3s manifests
        "L+ /var/lib/rancher/k3s/server/manifests/00-gitea-pvs.yaml - - - - ${giteaPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-gitea-helmchart.yaml - - - - ${giteaHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-gitea-cert.yaml - - - - ${giteaCert}"
        "L+ /var/lib/rancher/k3s/server/manifests/30-gitea-grafana-dashboard.yaml - - - - ${giteaGrafanaDashboard}"
        # To make homepage auto-get a token
        "L+ /var/lib/rancher/k3s/server/manifests/00-gitea-admin-secret.yaml - - - - ${giteaAdminSecret}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-gitea-token-rbac.yaml - - - - ${giteaTokenJobRbac}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-gitea-token-job.yaml - - - - ${giteaTokenJob}"
        # Ensure config dir exists with correct ownership
        "d ${cfg.config_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })

    (lib.mkIf (!cfg.enable) {
      # Clean up symlinks when disabled
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-gitea-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-gitea-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-gitea-cert.yaml"
        "r /var/lib/rancher/k3s/server/manifests/30-gitea-grafana-dashboard.yaml"
        "r /var/lib/rancher/k3s/server/manifests/00-gitea-admin-secret.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-gitea-token-rbac.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-gitea-token-job.yaml"
      ];
    })
  ];
}
