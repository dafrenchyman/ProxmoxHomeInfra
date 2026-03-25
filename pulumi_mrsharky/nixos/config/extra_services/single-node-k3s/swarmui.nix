{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.swarmui;
  parent = config.extraServices.single_node_k3s;
  containerPort = 7801;

  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  envList =
    [
      {
        name = "TZ";
        value = config.time.timeZone;
      }
      {
        name = "PYTHONUNBUFFERED";
        value = "1";
      }
      {
        name = "SWARM_ARGS";
        value = cfg.swarm_args;
      }
    ]
    ++ lib.mapAttrsToList (name: value: {
      inherit name;
      value = toString value;
    })
    cfg.extraEnv;

  envYaml = lib.generators.toYAML {} envList;
  nodeSelectorYaml = lib.generators.toYAML {} cfg.nodeSelector;
  persistenceYaml = lib.generators.toYAML {} {
    workspace = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.workspace_path;
      hostPathType = "DirectoryOrCreate";
      globalMounts = [
        {
          path = "/workspace";
          readOnly = false;
        }
      ];
    };
  };

  gpuResourcesYaml = lib.generators.toYAML {} {
    limits = {
      "nvidia.com/gpu" = toString cfg.gpu.count;
    };
    requests = {
      "nvidia.com/gpu" = toString cfg.gpu.count;
    };
  };

  appStartupScript = lib.concatStringsSep "\n" [
    "set -eux"
    "export DEBIAN_FRONTEND=noninteractive"
    "apt-get update"
    "apt-get install -y --no-install-recommends ca-certificates ffmpeg git libgl1 libglib2.0-0 python3 python3-dev python3-venv wget"
    "rm -rf /var/lib/apt/lists/*"
    "mkdir -p /workspace/linuxhome"
    ''
      if [ ! -d /workspace/SwarmUI/.git ]; then
        git clone --depth=1 ${cfg.repo_url} /workspace/SwarmUI
      fi
    ''
    (lib.optionalString cfg.auto_update ''
      git -C /workspace/SwarmUI pull --ff-only
    '')
    "cd /workspace/SwarmUI"
    "chmod +x launch-linux.sh"
    "# shellcheck disable=SC2086"
    "exec env HOME=/workspace/linuxhome ./launch-linux.sh --launch_mode none --host 0.0.0.0 --port ${toString containerPort} $SWARM_ARGS"
  ];

  swarmuiCert = pkgs.writeText "20-swarmui-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: swarmui-tls
      namespace: default
    spec:
      secretName: swarmui-tls-secret
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

  swarmuiHelmChart = pkgs.writeText "10-swarmui-helmchart.yaml" ''
        apiVersion: helm.cattle.io/v1
        kind: HelmChart
        metadata:
          name: swarmui
          namespace: kube-system
        spec:
          repo: https://bjw-s-labs.github.io/helm-charts/
          chart: app-template
          version: 4.3.0
          targetNamespace: default
          valuesContent: |
            controllers:
              main:
                type: deployment
                revisionHistoryLimit: 1
                strategy: Recreate
                pod:
        ${lib.optionalString cfg.gpu.enable (indent 10 ''runtimeClassName: "${cfg.runtimeClassName}"'')}
                  nodeSelector:
        ${indent 12 nodeSelectorYaml}
                containers:
                  app:
                    image:
                      repository: mcr.microsoft.com/dotnet/sdk
                      tag: ${cfg.image_tag}
                      pullPolicy: IfNotPresent
                    command:
                      - /bin/bash
                      - -lc
                    args:
                      - |
        ${indent 20 appStartupScript}
                    env:
        ${indent 18 envYaml}
    ${lib.optionalString cfg.gpu.enable ''
                  resources:
      ${indent 18 gpuResourcesYaml}
    ''}
            service:
              main:
                controller: main
                ports:
                  http:
                    port: ${toString containerPort}
            persistence:
        ${indent 6 persistenceYaml}
            podSecurityContext:
              fsGroup: 0
            securityContext:
              runAsUser: 0
              runAsGroup: 0
            ingress:
              main:
                enabled: true
                className: nginx
                annotations:
                  nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
                  gethomepage.dev/enabled: "true"
                  gethomepage.dev/group: AI
                  gethomepage.dev/name: SwarmUI
                  gethomepage.dev/description: SwarmUI with persisted workspace and Comfy backend support.
                  gethomepage.dev/siteMonitor: http://swarmui.default.svc.cluster.local:${toString containerPort}
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
                  - secretName: swarmui-tls-secret
                    hosts:
                      - ${cfg.subdomain}.${parent.full_hostname}
                      - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.swarmui = {
    enable = lib.mkEnableOption "SwarmUI service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "swarm";
      example = "swarm";
      description = "Subdomain prefix used for the SwarmUI ingress.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "8.0-bookworm-slim";
      description = "Container image tag for the SwarmUI runner.";
    };

    workspace_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/swarmui/workspace";
      description = "Host path mounted to /workspace for the SwarmUI checkout, data, and downloaded models.";
    };

    repo_url = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/mcmonkeyprojects/SwarmUI";
      description = "Git repository cloned into the persistent workspace on first start.";
    };

    auto_update = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to run git pull inside the SwarmUI workspace on container startup.";
    };

    swarm_args = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "--launch_mode none";
      description = "Additional arguments appended to SwarmUI's launch-linux.sh invocation.";
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NVIDIA GPU scheduling for the SwarmUI pod.";
      };

      count = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of GPUs requested via nvidia.com/gpu.";
      };
    };

    runtimeClassName = lib.mkOption {
      type = lib.types.str;
      default = "nvidia";
      description = "runtimeClassName to use when GPU support is enabled.";
    };

    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "kubernetes.io/hostname" = "gpu-node";
      };
      description = "Optional node selector for the SwarmUI pod.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.bool
      ]);
      default = {};
      description = "Extra environment variables for the SwarmUI container.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/10-swarmui-helmchart.yaml - - - - ${swarmuiHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-swarmui-cert.yaml - - - - ${swarmuiCert}"
        "d ${cfg.workspace_path} 0775 root root -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-swarmui-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-swarmui-cert.yaml"
      ];
    })
  ];
}
