{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.turbowarp;
  parent = config.extraServices.single_node_k3s;

  serviceName = "turbowarp";
  containerPort = 80;

  manifestDir = "/var/lib/rancher/k3s/server/manifests";
  uninstallStateDir = "/var/lib/rancher/k3s/server/uninstalling-manifests/${serviceName}";

  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  turbowarpCert = pkgs.writeText "05-turbowarp-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: turbowarp-tls
      namespace: default
    spec:
      secretName: turbowarp-tls-secret
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

  values = {
    controllers = {
      main = {
        containers = {
          app = {
            image = {
              tag = cfg.image_tag;
            };
          };
        };
      };
    };

    ingress = {
      main = {
        enabled = true;
        className = "nginx";
        annotations = {
          "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true";
          "gethomepage.dev/enabled" = "true";
          "gethomepage.dev/group" = "Tools";
          "gethomepage.dev/name" = "TurboWarp";
          "gethomepage.dev/description" = "Scratch-compatible editor for local self-hosting.";
          "gethomepage.dev/icon" = "turbowarp.png";
          "gethomepage.dev/href" = "https://${cfg.subdomain}.${parent.full_hostname}/editor.html";
          "gethomepage.dev/siteMonitor" = "http://${serviceName}.default.svc.cluster.local:${toString containerPort}/editor.html";
        };
        hosts = [
          {
            host = "${cfg.subdomain}.${parent.full_hostname}";
            paths = [
              {
                path = "/";
                pathType = "Prefix";
                service = {
                  identifier = "main";
                  port = "http";
                };
              }
            ];
          }
          {
            host = "${cfg.subdomain}.${parent.node_master_ip}.nip.io";
            paths = [
              {
                path = "/";
                pathType = "Prefix";
                service = {
                  identifier = "main";
                  port = "http";
                };
              }
            ];
          }
        ];
        tls = [
          {
            secretName = "turbowarp-tls-secret"; # pragma: allowlist secret
            hosts = [
              "${cfg.subdomain}.${parent.full_hostname}"
              "${cfg.subdomain}.${parent.node_master_ip}.nip.io"
            ];
          }
        ];
      };
    };
  };

  valuesYaml = lib.generators.toYAML {} values;

  turbowarpHelmChart = pkgs.writeText "10-turbowarp-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: turbowarp
      namespace: kube-system
    spec:
      repo: https://charts.mrsharky.com
      chart: turbowarp
      version: ${cfg.chart_version}
      targetNamespace: default
      valuesContent: |
    ${indent 4 valuesYaml}
  '';
in {
  options.extraServices.single_node_k3s.turbowarp = {
    enable = lib.mkEnableOption "TurboWarp service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "scratch";
      example = "scratch";
      description = "Subdomain prefix used for the TurboWarp ingress.";
    };

    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "0.1.0";
      description = "Version of the TurboWarp Helm chart from charts.mrsharky.com.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "upstream-a2946ee";
      example = "upstream-a2946ee";
      description = "TurboWarp container image tag.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/05-turbowarp-cert.yaml - - - - ${turbowarpCert}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-turbowarp-helmchart.yaml - - - - ${turbowarpHelmChart}"
      ];
    })

    (lib.mkIf (!cfg.enable) {
      systemd.services.uninstall-turbowarp = {
        description = "Uninstall TurboWarp from k3s";
        after = ["k3s.service"];
        wants = ["k3s.service"];
        wantedBy = ["multi-user.target"];
        path = [pkgs.k3s];

        serviceConfig = {
          Type = "oneshot";
        };

        script = ''
          set -euo pipefail

          manifest_exists() {
            [ -e "$1" ] || [ -L "$1" ]
          }

          stage_manifest() {
            name="$1"
            src="${manifestDir}/$name"
            dst="${uninstallStateDir}/$name"

            if manifest_exists "$src"; then
              mkdir -p "${uninstallStateDir}"
              mv -f "$src" "$dst"
            fi
          }

          staged_manifest_exists() {
            manifest_exists "${uninstallStateDir}/$1"
          }

          if \
            ! manifest_exists "${manifestDir}/10-turbowarp-helmchart.yaml" &&
            ! manifest_exists "${manifestDir}/05-turbowarp-cert.yaml" &&
            ! staged_manifest_exists "10-turbowarp-helmchart.yaml" &&
            ! staged_manifest_exists "05-turbowarp-cert.yaml"
          then
            echo "No TurboWarp manifests found; skipping uninstall."
            exit 0
          fi

          for attempt in $(seq 1 150); do
            if k3s kubectl get --raw=/readyz >/dev/null 2>&1; then
              break
            fi

            if [ "$attempt" -eq 150 ]; then
              echo "Timed out waiting for k3s API readiness." >&2
              exit 1
            fi

            sleep 2
          done

          stage_manifest "10-turbowarp-helmchart.yaml"
          stage_manifest "05-turbowarp-cert.yaml"

          if staged_manifest_exists "10-turbowarp-helmchart.yaml"; then
            k3s kubectl -n kube-system delete addon 10-turbowarp-helmchart --ignore-not-found
            k3s kubectl -n kube-system delete helmchart ${serviceName} --ignore-not-found --wait=true --timeout=5m
            rm -f "${uninstallStateDir}/10-turbowarp-helmchart.yaml"
          fi

          if staged_manifest_exists "05-turbowarp-cert.yaml"; then
            k3s kubectl -n kube-system delete addon 05-turbowarp-cert --ignore-not-found
            k3s kubectl delete certificate turbowarp-tls --ignore-not-found
            k3s kubectl delete secret turbowarp-tls-secret --ignore-not-found
            rm -f "${uninstallStateDir}/05-turbowarp-cert.yaml"
          fi

          rmdir "${uninstallStateDir}" 2>/dev/null || true
        '';
      };
    })
  ];
}
