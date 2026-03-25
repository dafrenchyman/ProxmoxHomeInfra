{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.fooocus;
  parent = config.extraServices.single_node_k3s;
  fooocusPort = 7865;

  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  persistenceYaml = lib.generators.toYAML {} {
    models = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.models_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/content/data/models";
          readOnly = false;
        }
      ];
    };
    outputs = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.outputs_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/content/data/outputs";
          readOnly = false;
        }
      ];
    };
    runtime-state = {
      enabled = true;
      type = "hostPath";
      hostPath = cfg.state_path;
      hostPathType = "DirectoryOrCreate";
      advancedMounts.main.app = [
        {
          path = "/content/data/state";
          readOnly = false;
        }
      ];
    };
  };

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

  nodeSelectorYaml = lib.generators.toYAML {} cfg.nodeSelector;

  ingressAnnotationsYaml = lib.generators.toYAML {} {
    "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true";
    "gethomepage.dev/enabled" = "true";
    "gethomepage.dev/group" = "AI";
    "gethomepage.dev/name" = "Fooocus";
    "gethomepage.dev/description" = "Simple text-to-image web UI focused on prompting and generating.";
    "gethomepage.dev/icon" = "https://www.gradio.app/favicon.png";
    "gethomepage.dev/siteMonitor" = "http://fooocus.default.svc.cluster.local:${toString fooocusPort}";
  };
  tolerationsYaml = lib.generators.toYAML {} cfg.tolerations;
  affinityYaml = lib.generators.toYAML {} cfg.affinity;
  containerSecurityContextYaml = lib.generators.toYAML {} cfg.containerSecurityContext;

  fooocusCert = pkgs.writeText "20-fooocus-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: fooocus-tls
      namespace: default
    spec:
      secretName: fooocus-tls-secret
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

  fooocusHelmChart = pkgs.writeText "10-fooocus-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: fooocus
      namespace: kube-system
    spec:
      repo: https://charts.mrsharky.com
      chart: fooocus_extend
      version: 0.1.0
      targetNamespace: default
      valuesContent: |
        image:
          tag: ${cfg.image_tag}
        fooocusExtend:
          timezone: ${config.time.timeZone}
          uid: "${toString cfg.uid}"
          gid: "${toString cfg.gid}"
          port: ${toString fooocusPort}
          cmdArgs: "${cfg.fooocus_args}"
          replicas: ${toString cfg.replicas}
        resources:
    ${indent 6 resourcesYaml}
        nodeSelector:
    ${indent 6 nodeSelectorYaml}
        tolerations:
    ${indent 6 tolerationsYaml}
        affinity:
    ${indent 6 affinityYaml}
        defaultPodOptions:
    ${indent 6 defaultPodOptionsYaml}
        containerSecurityContext:
    ${indent 6 containerSecurityContextYaml}
        persistence:
    ${indent 6 persistenceYaml}
        ingress:
          main:
            enabled: true
            className: nginx
            annotations:
    ${indent 12 ingressAnnotationsYaml}
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
              - secretName: fooocus-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.fooocus = {
    enable = lib.mkEnableOption "Fooocus service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "fooocus";
      example = "images";
      description = "Subdomain prefix used for the Fooocus ingress.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "latest";
      description = "Container image tag for the Fooocus Extend chart.";
    };

    models_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/fooocus/models";
      description = "Host path for Fooocus model assets.";
    };

    outputs_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/fooocus/outputs";
      description = "Host path for generated Fooocus outputs.";
    };

    state_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/fooocus/state";
      description = "Host path for smaller Fooocus runtime state such as config, presets, styles, and wildcards.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "UID passed to the Fooocus Extend container for writable hostPath volumes.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "GID and fsGroup used for writable hostPath volumes.";
    };

    fooocus_args = lib.mkOption {
      type = lib.types.str;
      default = "--listen";
      example = "--listen --preset realistic";
      description = "Arguments passed to Fooocus Extend on startup.";
    };

    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Replica count for the Fooocus deployment.";
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NVIDIA GPU scheduling for the Fooocus pod.";
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
      description = "Optional node selector for the Fooocus pod.";
    };

    tolerations = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "Optional Kubernetes tolerations for the Fooocus pod.";
    };

    affinity = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Optional Kubernetes affinity for the Fooocus pod.";
    };

    containerSecurityContext = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Optional container-level security context overrides passed to the chart.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/10-fooocus-helmchart.yaml - - - - ${fooocusHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-fooocus-cert.yaml - - - - ${fooocusCert}"
        "d ${cfg.models_path} 0755 root root -"
        "d ${cfg.outputs_path} 0755 root root -"
        "d ${cfg.state_path} 0755 root root -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-fooocus-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-fooocus-cert.yaml"
      ];
    })
  ];
}
