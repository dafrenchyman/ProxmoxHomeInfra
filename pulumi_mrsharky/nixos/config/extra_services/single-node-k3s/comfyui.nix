{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.comfyui;
  parent = config.extraServices.single_node_k3s;

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
        name = "PUID";
        value = toString cfg.uid;
      }
      {
        name = "PGID";
        value = toString cfg.gid;
      }
      {
        name = "COMFYUI_TEMP_DIR";
        value = "/opt/comfyui/temp";
      }
      {
        name = "SECRET_KEY";
        valueFrom.secretKeyRef = {
          name = "comfyui-sentinel-secret";
          key = "SECRET_KEY";
        };
      }
    ]
    ++ lib.optional (cfg.cli_args != "") {
      name = "COMFYUI_EXTRA_ARGS";
      value = cfg.cli_args;
    }
    ++ lib.mapAttrsToList (name: value: {
      inherit name;
      value = toString value;
    })
    cfg.extraEnv;

  envYaml = lib.generators.toYAML {} envList;

  persistenceAttrs = {
    models = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.models_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main =
        {
          app = [
            {
              path = "/opt/comfyui/models";
              readOnly = false;
            }
          ];
        }
        // lib.optionalAttrs (cfg.starter_models != []) {
          starter-models = [
            {
              path = "/opt/comfyui/models";
              readOnly = false;
            }
          ];
        };
    };
    input = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.input_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/opt/comfyui/input";
          readOnly = false;
        }
      ];
    };
    output = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.output_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/opt/comfyui/output";
          readOnly = false;
        }
      ];
    };
    sentinel-state = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.sentinel_state_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/opt/comfyui/state/sentinel";
          readOnly = false;
        }
      ];
    };
    user = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.user_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/opt/comfyui/user";
          readOnly = false;
        }
      ];
    };
    temp = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.temp_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/opt/comfyui/temp";
          readOnly = false;
        }
      ];
    };
    custom-nodes = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.custom_nodes_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/opt/comfyui/custom_nodes";
          readOnly = false;
        }
      ];
    };
  };

  persistenceYaml = lib.generators.toYAML {} persistenceAttrs;

  defaultPodOptionsYaml = lib.generators.toYAML {} (
    {
      securityContext = {
        fsGroup = cfg.gid;
        fsGroupChangePolicy = "OnRootMismatch";
      };
    }
    // lib.optionalAttrs cfg.gpu.enable {
      runtimeClassName = cfg.runtimeClassName;
    }
  );

  resourcesYaml = lib.generators.toYAML {} {
    requests =
      {
        cpu = "500m";
        memory = "4Gi";
      }
      // lib.optionalAttrs cfg.gpu.enable {
        "nvidia.com/gpu" = cfg.gpu.count;
      };
    limits =
      {
        memory = "12Gi";
      }
      // lib.optionalAttrs cfg.gpu.enable {
        "nvidia.com/gpu" = cfg.gpu.count;
      };
  };

  starterModelScript =
    ''
      set -eu
      apk add --no-cache curl ca-certificates >/dev/null
    ''
    + lib.concatMapStringsSep "\n" (
      model: let
        filename =
          if model.filename != null
          then model.filename
          else builtins.baseNameOf model.url;
        targetDir = "/opt/comfyui/models/${model.target_subdir}";
        targetFile = "${targetDir}/${filename}";
      in ''
        mkdir -p "${targetDir}"
        if [ ! -f "${targetFile}" ]; then
          echo "Downloading ${model.url} -> ${targetFile}"
          curl -L --fail --retry 3 --output "${targetFile}" "${model.url}"
        fi
      ''
    )
    cfg.starter_models;

  initContainersAttrs = lib.optionalAttrs (cfg.starter_models != []) {
    starter-models = {
      image = {
        repository = "alpine";
        tag = "3.21";
        pullPolicy = "IfNotPresent";
      };
      command = [
        "/bin/sh"
        "-c"
      ];
      args = [starterModelScript];
    };
  };

  initContainersYaml = lib.generators.toYAML {} initContainersAttrs;

  comfyuiCert = pkgs.writeText "20-comfyui-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: comfyui-tls
      namespace: default
    spec:
      secretName: comfyui-tls-secret
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

  comfyuiHelmChart = pkgs.writeText "10-comfyui-helmchart.yaml" (
    ''
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: comfyui
        namespace: kube-system
      spec:
        repo: http://charts.mrsharky.com
        chart: comfyui
        version: 0.1.2
        targetNamespace: default
        valuesContent: |
          defaultPodOptions:
    ''
    + indent 10 defaultPodOptionsYaml
    + ''
      controllers:
        main:
          type: deployment
          revisionHistoryLimit: 1
          strategy: Recreate
          pod:
            nodeSelector:
    ''
    + indent 16 (lib.generators.toYAML {} cfg.nodeSelector)
    + lib.optionalString (initContainersAttrs != {}) ''
                  initContainers:
      ${indent 14 initContainersYaml}
    ''
    + ''
      containers:
        app:
          image:
            repository: ghcr.io/dafrenchyman/comfyui
            tag: ${cfg.image_tag}
            pullPolicy: IfNotPresent
          env:
    ''
    + indent 18 envYaml
    + ''
      resources:
    ''
    + indent 18 resourcesYaml
    + ''
              ports:
                - name: web
                  containerPort: 8188
                  protocol: TCP
              probes:
                startup:
                  enabled: true
                  custom: true
                  spec:
                    tcpSocket:
                      port: web
                    initialDelaySeconds: 10
                    periodSeconds: 10
                    timeoutSeconds: 5
                    failureThreshold: 30
                readiness:
                  enabled: true
                  custom: true
                  spec:
                    tcpSocket:
                      port: web
                    initialDelaySeconds: 20
                    periodSeconds: 15
                    timeoutSeconds: 5
                    failureThreshold: 6
                liveness:
                  enabled: true
                  custom: true
                  spec:
                    tcpSocket:
                      port: web
                    initialDelaySeconds: 60
                    periodSeconds: 30
                    timeoutSeconds: 5
                    failureThreshold: 5
      service:
        main:
          enabled: true
          controller: main
          type: ClusterIP
          ports:
            http:
              port: 8188
              targetPort: web
              protocol: TCP

      persistence:
    ''
    + indent 10 persistenceYaml
    + ''

      ingress:
        main:
          enabled: true
          className: nginx
          annotations:
            nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
            gethomepage.dev/enabled: "true"
            gethomepage.dev/group: AI
            gethomepage.dev/name: ComfyUI
            gethomepage.dev/description: ComfyUI with bundled ComfyUI-Manager.
            gethomepage.dev/icon: comfyui.svg
            gethomepage.dev/siteMonitor: http://comfyui.default.svc.cluster.local:8188
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
            - secretName: comfyui-tls-secret
              hosts:
                - ${cfg.subdomain}.${parent.full_hostname}
                - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
    ''
  );
in {
  options.extraServices.single_node_k3s.comfyui = {
    enable = lib.mkEnableOption "ComfyUI service deployed from the mrsharky Helm chart";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "comfyui";
      example = "comfy";
      description = "Subdomain prefix used for the ComfyUI ingress.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "latest";
      description = "Pinned ComfyUI Docker image tag.";
    };

    cli_args = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "--preview-method auto";
      description = "Additional CLI arguments appended to the ComfyUI startup command.";
    };

    models_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/comfyui/models";
      description = "Host path mounted to /opt/comfyui/models.";
    };

    input_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/comfyui/input";
      description = "Host path mounted to /opt/comfyui/input.";
    };

    output_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/comfyui/output";
      description = "Host path mounted to /opt/comfyui/output.";
    };

    sentinel_state_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/comfyui/sentinel";
      description = "Host path mounted to /opt/comfyui/state/sentinel.";
    };

    user_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/comfyui/user";
      description = "Host path mounted to /opt/comfyui/user.";
    };

    temp_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/comfyui/temp";
      description = "Host path mounted to /opt/comfyui/temp.";
    };

    custom_nodes_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/comfyui/custom_nodes";
      description = "Host path mounted to /opt/comfyui/custom_nodes.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "User id mapped into the container via PUID.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "Group id mapped into the container via PGID.";
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NVIDIA GPU scheduling for the ComfyUI pod.";
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

    manager = {
      security_level = lib.mkOption {
        type = lib.types.enum [
          "strong"
          "normal"
          "normal-"
          "weak"
        ];
        default = "weak";
        description = "Legacy option retained for compatibility; the custom chart now configures ComfyUI-Manager through the baked container.";
      };
    };

    starter_models = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ({...}: {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Direct download URL for the model file.";
          };

          target_subdir = lib.mkOption {
            type = lib.types.str;
            example = "checkpoints";
            description = "Subdirectory under /opt/comfyui/models where the model should be downloaded.";
          };

          filename = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional filename override. Defaults to the basename of the URL.";
          };
        };
      }));
      default = [];
      example = [
        {
          url = "https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev.safetensors";
          target_subdir = "checkpoints";
          filename = "flux1-dev.safetensors";
        }
      ];
      description = "Optional starter models to download into the ComfyUI models directory during pod initialization.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.bool
      ]);
      default = {};
      example = {
        HF_HOME = "/opt/comfyui/user/.cache/huggingface";
      };
      description = "Extra environment variables for the ComfyUI container.";
    };

    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "kubernetes.io/hostname" = "gpu-node";
      };
      description = "Optional node selector for the ComfyUI pod.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/10-comfyui-helmchart.yaml - - - - ${comfyuiHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-comfyui-cert.yaml - - - - ${comfyuiCert}"
        "d ${cfg.models_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.input_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.output_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.sentinel_state_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.user_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.temp_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
        "d ${cfg.custom_nodes_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-comfyui-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-comfyui-cert.yaml"
      ];
    })
  ];
}
