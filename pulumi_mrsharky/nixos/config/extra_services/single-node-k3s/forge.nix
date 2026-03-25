{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.forge;
  parent = config.extraServices.single_node_k3s;
  publicPort = 7860;
  containerPort = 17860;

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
        name = "AUTO_UPDATE";
        value =
          if cfg.auto_update
          then "true"
          else "false";
      }
      {
        name = "FORGE_ARGS";
        value = cfg.forge_args;
      }
      {
        name = "FORGE_PORT_HOST";
        value = toString publicPort;
      }
      {
        name = "FORGE_URL";
        value = "https://${cfg.subdomain}.${parent.full_hostname}";
      }
      {
        name = "WEB_ENABLE_AUTH";
        value =
          if cfg.web_enable_auth
          then "true"
          else "false";
      }
      {
        name = "CF_QUICK_TUNNELS";
        value = "false";
      }
      {
        name = "WORKSPACE";
        value = "/workspace";
      }
      {
        name = "SUPERVISOR_NO_AUTOSTART";
        value = "caddy,cloudflared,jupyter,quicktunnel,serviceportal,sshd,syncthing";
      }
    ]
    ++ lib.optionals (cfg.forge_ref != null) [
      {
        name = "FORGE_REF";
        value = cfg.forge_ref;
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

  forgeCert = pkgs.writeText "20-forge-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: forge-tls
      namespace: default
    spec:
      secretName: forge-tls-secret
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

  forgeHelmChart = pkgs.writeText "10-forge-helmchart.yaml" ''
        apiVersion: helm.cattle.io/v1
        kind: HelmChart
        metadata:
          name: forge
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
                      repository: ghcr.io/ai-dock/stable-diffusion-webui-forge
                      tag: ${cfg.image_tag}
                      pullPolicy: IfNotPresent
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
              fsGroup: ${toString cfg.gid}
            securityContext:
              runAsUser: ${toString cfg.uid}
              runAsGroup: ${toString cfg.gid}
            ingress:
              main:
                enabled: true
                className: nginx
                annotations:
                  nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
                  gethomepage.dev/enabled: "true"
                  gethomepage.dev/group: AI
                  gethomepage.dev/name: Forge
                  gethomepage.dev/description: Stable Diffusion WebUI Forge.
                  gethomepage.dev/siteMonitor: http://forge.default.svc.cluster.local:${toString publicPort}
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
                  - secretName: forge-tls-secret
                    hosts:
                      - ${cfg.subdomain}.${parent.full_hostname}
                      - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.forge = {
    enable = lib.mkEnableOption "Stable Diffusion WebUI Forge service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "forge";
      example = "forge";
      description = "Subdomain prefix used for the Forge ingress.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "v2-cuda-12.1.1-base-22.04";
      description = "Container image tag for Forge.";
    };

    workspace_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/forge/workspace";
      description = "Host path mounted to /workspace for Forge data, models, outputs, and extensions.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "User id used by the Forge container.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "Group id used by the Forge container.";
    };

    auto_update = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the Forge container should update Forge itself on startup.";
    };

    forge_ref = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Git ref for Forge auto-update. Null uses the image default.";
    };

    forge_args = lib.mkOption {
      type = lib.types.str;
      default = "--listen --api";
      example = "--listen --api --always-offload-from-vram";
      description = "Arguments passed to Forge on startup via FORGE_ARGS.";
    };

    web_enable_auth = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable AI-Dock's built-in web authentication portal. Disable this when Forge is exposed through cluster ingress.";
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NVIDIA GPU scheduling for the Forge pod.";
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
      description = "Optional node selector for the Forge pod.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.bool
      ]);
      default = {};
      example = {
        HF_TOKEN = "token-if-needed";
      };
      description = "Extra environment variables for the Forge container.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/10-forge-helmchart.yaml - - - - ${forgeHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-forge-cert.yaml - - - - ${forgeCert}"
        "d ${cfg.workspace_path} 0775 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-forge-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-forge-cert.yaml"
      ];
    })
  ];
}
