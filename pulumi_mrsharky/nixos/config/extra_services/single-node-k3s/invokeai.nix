{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.invokeai;
  parent = config.extraServices.single_node_k3s;
  containerPort = 9090;
  manifestAddonNames = [
    "10-invokeai-helmchart"
    "20-invokeai-cert"
  ];

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
        name = "INVOKEAI_ROOT";
        value = "/invokeai";
      }
      {
        name = "INVOKEAI_HOST";
        value = "0.0.0.0";
      }
      {
        name = "INVOKEAI_PORT";
        value = toString containerPort;
      }
    ]
    ++ lib.optional cfg.auto_update {
      name = "INVOKEAI_AUTO_UPDATE";
      value = "true";
    }
    ++ lib.mapAttrsToList (name: value: {
      inherit name;
      value = toString value;
    })
    cfg.extraEnv;

  envYaml = lib.generators.toYAML {} envList;
  nodeSelectorYaml = lib.generators.toYAML {} cfg.nodeSelector;
  persistenceYaml = lib.generators.toYAML {} {
    root = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.root_path;
      hostPathType = "DirectoryOrCreate";
      globalMounts = [
        {
          path = "/invokeai";
          readOnly = false;
        }
      ];
    };
  };
  gpuResourcesYaml = lib.generators.toYAML {} {
    limits."nvidia.com/gpu" = toString cfg.gpu.count;
    requests."nvidia.com/gpu" = toString cfg.gpu.count;
  };

  valuesContent = lib.concatStringsSep "\n" (
    [
      "controllers:"
      "  main:"
      "    type: deployment"
      "    revisionHistoryLimit: 1"
      "    strategy: Recreate"
      "    pod:"
    ]
    ++ lib.optionals cfg.gpu.enable [
      "      runtimeClassName: \"${cfg.runtimeClassName}\""
    ]
    ++ [
      "      nodeSelector:"
    ]
    ++ lib.splitString "\n" (indent 8 nodeSelectorYaml)
    ++ [
      "    containers:"
      "      app:"
      "        image:"
      "          repository: ghcr.io/invoke-ai/invokeai"
      "          tag: ${cfg.image_tag}"
      "          pullPolicy: IfNotPresent"
      "        env:"
    ]
    ++ lib.splitString "\n" (indent 10 envYaml)
    ++ lib.optionals cfg.gpu.enable (
      [
        "        resources:"
      ]
      ++ lib.splitString "\n" (indent 10 gpuResourcesYaml)
    )
    ++ [
      "service:"
      "  main:"
      "    controller: main"
      "    ports:"
      "      http:"
      "        port: ${toString containerPort}"
      "persistence:"
    ]
    ++ lib.splitString "\n" (indent 2 persistenceYaml)
    ++ [
      "ingress:"
      "  main:"
      "    enabled: true"
      "    className: nginx"
      "    annotations:"
      "      nginx.ingress.kubernetes.io/force-ssl-redirect: \"true\""
      "      gethomepage.dev/enabled: \"true\""
      "      gethomepage.dev/group: AI"
      "      gethomepage.dev/name: InvokeAI"
      "      gethomepage.dev/description: InvokeAI with built-in model manager."
      "      gethomepage.dev/icon: invoke-ai"
      "      gethomepage.dev/siteMonitor: http://invokeai.default.svc.cluster.local:${toString containerPort}"
      "    hosts:"
      "      - host: ${cfg.subdomain}.${parent.full_hostname}"
      "        paths:"
      "          - path: /"
      "            pathType: Prefix"
      "            service:"
      "              identifier: main"
      "              port: http"
      "      - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io"
      "        paths:"
      "          - path: /"
      "            pathType: Prefix"
      "            service:"
      "              identifier: main"
      "              port: http"
      "    tls:"
      "      - secretName: invokeai-tls-secret"
      "        hosts:"
      "          - ${cfg.subdomain}.${parent.full_hostname}"
      "          - ${cfg.subdomain}.${parent.node_master_ip}.nip.io"
    ]
  );

  invokeaiCert = pkgs.writeText "20-invokeai-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: invokeai-tls
      namespace: default
    spec:
      secretName: invokeai-tls-secret
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

  invokeaiHelmChart = pkgs.writeText "10-invokeai-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: invokeai
      namespace: kube-system
    spec:
      repo: https://bjw-s-labs.github.io/helm-charts/
      chart: app-template
      version: 4.3.0
      targetNamespace: default
      valuesContent: |
    ${indent 8 valuesContent}
  '';
in {
  options.extraServices.single_node_k3s.invokeai = {
    enable = lib.mkEnableOption "InvokeAI service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "invoke";
      example = "invoke";
      description = "Subdomain prefix used for the InvokeAI ingress.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "sha-c6a9847-cuda";
      description = "InvokeAI container image tag.";
    };

    root_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/invokeai";
      description = "Host path mounted to /invokeai for models, config, and outputs.";
    };

    auto_update = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set InvokeAI auto-update env on container startup.";
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NVIDIA GPU scheduling for the InvokeAI pod.";
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
      description = "Optional node selector for the InvokeAI pod.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.bool
      ]);
      default = {};
      example = {
        HUGGING_FACE_HUB_TOKEN = "hf_token";
      };
      description = "Extra environment variables for the InvokeAI container.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/10-invokeai-helmchart.yaml - - - - ${invokeaiHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-invokeai-cert.yaml - - - - ${invokeaiCert}"
        "d ${cfg.root_path} 0775 root root -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      services.k3s.extraFlags = lib.mkAfter (
        lib.optionals parent.enable (map (addonName: "--disable=${addonName}") manifestAddonNames)
      );
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-invokeai-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-invokeai-cert.yaml"
      ];
    })
  ];
}
