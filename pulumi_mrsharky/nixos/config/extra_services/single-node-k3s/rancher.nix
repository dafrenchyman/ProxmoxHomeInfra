{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.rancher;
  parent = config.extraServices.single_node_k3s;

  rancherHostname = "${cfg.subdomain}.${parent.full_hostname}";

  rancherNamespace = pkgs.writeText "00-rancher-namespace.yaml" ''
    apiVersion: v1
    kind: Namespace
    metadata:
      name: cattle-system
  '';

  rancherCert = pkgs.writeText "10-rancher-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: tls-rancher-ingress
      namespace: cattle-system
    spec:
      secretName: tls-rancher-ingress
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${rancherHostname}
      dnsNames:
        - ${rancherHostname}
      duration: 2160h    # 90 days
      renewBefore: 360h  # 15 days before expiration
  '';

  rancherPlaceholderCaSecret = pkgs.writeText "14-rancher-placeholder-ca-secret.yaml" ''
    apiVersion: v1
    kind: Secret
    metadata:
      name: tls-ca
      namespace: cattle-system
    type: Opaque
    stringData:
      cacerts.pem: ""
  '';

  rancherCaSyncRbac = pkgs.writeText "15-rancher-ca-sync-rbac.yaml" ''
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: rancher-ca-sync
      namespace: cattle-system
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: rancher-ca-sync
      namespace: cattle-system
    rules:
      - apiGroups: [""]
        resources: ["secrets"]
        verbs: ["get", "list", "create", "update", "patch"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: rancher-ca-sync
      namespace: cattle-system
    subjects:
      - kind: ServiceAccount
        name: rancher-ca-sync
        namespace: cattle-system
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: rancher-ca-sync
  '';

  rancherCaSyncJob = pkgs.writeText "16-rancher-ca-sync-job.yaml" ''
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: rancher-ca-sync
      namespace: cattle-system
    spec:
      backoffLimit: 12
      template:
        spec:
          serviceAccountName: rancher-ca-sync
          restartPolicy: OnFailure
          containers:
            - name: sync-ca
              image: registry.suse.com/suse/kubectl:1.35
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  TMP_CA=/tmp/cacerts.pem

                  until kubectl -n cattle-system get secret tls-rancher-ingress >/dev/null 2>&1; do
                    sleep 5
                  done

                  while true; do
                    CA_CRT_B64="$(kubectl -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.ca\.crt}' || true)"
                    if [ -n "$CA_CRT_B64" ]; then
                      break
                    fi
                    sleep 5
                  done

                  printf '%s' "$CA_CRT_B64" | base64 -d > "$TMP_CA"

                  kubectl -n cattle-system create secret generic tls-ca \
                    --from-file=cacerts.pem="$TMP_CA" \
                    --dry-run=client -o yaml \
                    | kubectl apply -f -
  '';

  rancherCaSyncCronJob = pkgs.writeText "17-rancher-ca-sync-cronjob.yaml" ''
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: rancher-ca-sync-recurring
      namespace: cattle-system
    spec:
      schedule: "0 */6 * * *"
      concurrencyPolicy: Forbid
      jobTemplate:
        spec:
          backoffLimit: 2
          template:
            spec:
              serviceAccountName: rancher-ca-sync
              restartPolicy: OnFailure
              containers:
                - name: sync-ca
                  image: registry.suse.com/suse/kubectl:1.35
                  command: ["/bin/sh", "-c"]
                  args:
                    - |
                      set -eu
                      TMP_CA=/tmp/cacerts.pem

                      CA_CRT_B64="$(kubectl -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.ca\.crt}' || true)"
                      [ -n "$CA_CRT_B64" ] || exit 0

                      printf '%s' "$CA_CRT_B64" | base64 -d > "$TMP_CA"

                      kubectl -n cattle-system create secret generic tls-ca \
                        --from-file=cacerts.pem="$TMP_CA" \
                        --dry-run=client -o yaml \
                        | kubectl apply -f -
  '';

  rancherHelmChart = pkgs.writeText "20-rancher-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: rancher
      namespace: kube-system
    spec:
      repo: https://releases.rancher.com/server-charts/stable
      chart: rancher
      version: ${cfg.chart_version}
      targetNamespace: cattle-system
      valuesContent: |
        hostname: ${builtins.toJSON rancherHostname}
        replicas: ${toString cfg.replicas}
        antiAffinity: preferred
        ingress:
          ingressClassName: ${builtins.toJSON cfg.ingress_class_name}
          extraAnnotations:
            gethomepage.dev/enabled: "true"
            gethomepage.dev/group: Tools
            gethomepage.dev/name: Rancher
            gethomepage.dev/description: Centralized Kubernetes and cluster management UI.
            gethomepage.dev/icon: rancher.png
            gethomepage.dev/href: https://${rancherHostname}/
            gethomepage.dev/siteMonitor: https://${rancherHostname}/
          tls:
            source: secret
        privateCA: ${
      if cfg.private_ca
      then "true"
      else "false"
    }
        ${lib.optionalString (cfg.bootstrap_password != null) "bootstrapPassword: ${builtins.toJSON cfg.bootstrap_password}"}
  '';
in {
  options.extraServices.single_node_k3s.rancher = {
    enable = lib.mkEnableOption "Rancher management UI";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "rancher";
      example = "rancher";
      description = "Subdomain prefix used for the Rancher ingress.";
    };

    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "2.13.3";
      description = "Pinned Rancher Helm chart version.";
    };

    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
      example = 1;
      description = "Number of Rancher server replicas. Keep this at 1 for a single-node cluster.";
    };

    ingress_class_name = lib.mkOption {
      type = lib.types.str;
      default = "nginx";
      example = "nginx";
      description = "IngressClass used by Rancher.";
    };

    private_ca = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Rancher should trust a private CA for its ingress certificate.";
    };

    bootstrap_password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ChangeMe123456";
      description = ''
        Optional bootstrap password for the initial Rancher admin login.
        If null, Rancher generates one and stores it in the bootstrap-secret.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules =
        [
          "L+ /var/lib/rancher/k3s/server/manifests/00-rancher-namespace.yaml - - - - ${rancherNamespace}"
          "L+ /var/lib/rancher/k3s/server/manifests/10-rancher-cert.yaml - - - - ${rancherCert}"
          "L+ /var/lib/rancher/k3s/server/manifests/14-rancher-placeholder-ca-secret.yaml - - - - ${rancherPlaceholderCaSecret}"
          "L+ /var/lib/rancher/k3s/server/manifests/20-rancher-helmchart.yaml - - - - ${rancherHelmChart}"
        ]
        ++ lib.optionals cfg.private_ca [
          "L+ /var/lib/rancher/k3s/server/manifests/15-rancher-ca-sync-rbac.yaml - - - - ${rancherCaSyncRbac}"
          "L+ /var/lib/rancher/k3s/server/manifests/16-rancher-ca-sync-job.yaml - - - - ${rancherCaSyncJob}"
          "L+ /var/lib/rancher/k3s/server/manifests/17-rancher-ca-sync-cronjob.yaml - - - - ${rancherCaSyncCronJob}"
        ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-rancher-namespace.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-rancher-cert.yaml"
        "r /var/lib/rancher/k3s/server/manifests/14-rancher-placeholder-ca-secret.yaml"
        "r /var/lib/rancher/k3s/server/manifests/15-rancher-ca-sync-rbac.yaml"
        "r /var/lib/rancher/k3s/server/manifests/16-rancher-ca-sync-job.yaml"
        "r /var/lib/rancher/k3s/server/manifests/17-rancher-ca-sync-cronjob.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-rancher-helmchart.yaml"
      ];
    })
  ];
}
