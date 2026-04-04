{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.ace_step_1_5;
  parent = config.extraServices.single_node_k3s;
  aceStepPort = 7860;

  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  resourcesYaml = lib.generators.toYAML {} (
    {
      requests = {
        cpu = cfg.cpu_request;
        memory = cfg.memory_request;
      };
    }
    // lib.optionalAttrs cfg.gpu.enable {
      limits = {
        "nvidia.com/gpu" = cfg.gpu.count;
      };
    }
  );

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

  nodeSelectorYaml = lib.generators.toYAML {} cfg.nodeSelector;
  tolerationsYaml = lib.generators.toYAML {} cfg.tolerations;
  affinityYaml = lib.generators.toYAML {} cfg.affinity;
  containerSecurityContextYaml = lib.generators.toYAML {} cfg.containerSecurityContext;

  aceStepCert = pkgs.writeText "20-ace-step-1-5-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: ace-step-1-5-tls
      namespace: default
    spec:
      secretName: ace-step-1-5-tls-secret
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

  aceStepHelmChart = pkgs.writeText "10-ace-step-1-5-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: ace-step-1-5
      namespace: kube-system
    spec:
      repo: https://charts.mrsharky.com
      chart: ace-step-1-5
      version: ${cfg.chart_version}
      targetNamespace: default
      valuesContent: |
        image:
          tag: ${cfg.image_tag}
        aceStep:
          timezone: ${config.time.timeZone}
          uid: "${toString cfg.uid}"
          gid: "${toString cfg.gid}"
          host: ${cfg.host}
          port: ${toString aceStepPort}
          language: ${cfg.language}
          configPath: ${cfg.config_path}
          lmModelPath: ${cfg.lm_model_path}
          device: ${cfg.device}
          lmBackend: ${cfg.lm_backend}
          initLlm: ${cfg.init_llm}
          downloadSource: ${cfg.download_source}
          noInit: ${lib.boolToString cfg.no_init}
          extraArgs: "${cfg.extra_args}"
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
          models:
            enabled: true
            type: hostPath
            hostPath: ${cfg.models_path}
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /opt/ace-step/data/models
                    readOnly: false
          inputs:
            enabled: true
            type: hostPath
            hostPath: ${cfg.inputs_path}
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /opt/ace-step/data/inputs
                    readOnly: false
          outputs:
            enabled: true
            type: hostPath
            hostPath: ${cfg.outputs_path}
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /opt/ace-step/data/outputs
                    readOnly: false
          runtime-state:
            enabled: true
            type: hostPath
            hostPath: ${cfg.state_path}
            hostPathType: DirectoryOrCreate
            advancedMounts:
              main:
                app:
                  - path: /opt/ace-step/data/state
                    readOnly: false
        ingress:
          main:
            enabled: true
            className: nginx
            annotations:
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: AI
              gethomepage.dev/name: ACE-Step 1.5
              gethomepage.dev/description: Music generation web UI powered by ACE-Step 1.5.
              gethomepage.dev/icon: https://www.gradio.app/favicon.png
              gethomepage.dev/siteMonitor: http://ace-step-1-5.default.svc.cluster.local:${toString aceStepPort}
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
              - secretName: ace-step-1-5-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
  '';
in {
  options.extraServices.single_node_k3s.ace_step_1_5 = {
    enable = lib.mkEnableOption "ACE-Step 1.5 service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "ace-step";
      example = "music";
      description = "Subdomain prefix used for the ACE-Step 1.5 ingress.";
    };

    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "0.1.1";
      description = "Helm chart version for ACE-Step 1.5.";
    };

    image_tag = lib.mkOption {
      type = lib.types.str;
      default = "sha-4b883d5";
      description = "Container image tag for ACE-Step 1.5.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "UID passed to the ACE-Step container for writable hostPath volumes.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "GID and fsGroup used for writable hostPath volumes.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Listen address passed to the ACE-Step web UI.";
    };

    language = lib.mkOption {
      type = lib.types.str;
      default = "en";
      description = "ACE-Step UI language.";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      default = "acestep-v15-turbo";
      description = "Default DiT model selection passed as ACESTEP_CONFIG_PATH.";
    };

    lm_model_path = lib.mkOption {
      type = lib.types.str;
      default = "acestep-5Hz-lm-1.7B";
      description = "Default language-model selection passed as ACESTEP_LM_MODEL_PATH.";
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "cuda";
      description = "Device selection forwarded to ACE-Step.";
    };

    lm_backend = lib.mkOption {
      type = lib.types.str;
      default = "pt";
      description = "Language-model backend forwarded to ACE-Step.";
    };

    init_llm = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "LLM initialization mode forwarded to ACE-Step.";
    };

    download_source = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "Preferred model download source.";
    };

    no_init = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Skip eager model initialization during startup.";
    };

    extra_args = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Additional CLI arguments appended to the ACE-Step Gradio launch command.";
    };

    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Replica count for the ACE-Step deployment.";
    };

    cpu_request = lib.mkOption {
      type = lib.types.str;
      default = "500m";
      description = "CPU request for the ACE-Step container.";
    };

    memory_request = lib.mkOption {
      type = lib.types.str;
      default = "4Gi";
      description = "Memory request for the ACE-Step container.";
    };

    models_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/ace-step-1-5/models";
      description = "Host path for ACE-Step model assets.";
    };

    inputs_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/ace-step-1-5/inputs";
      description = "Host path for user-provided ACE-Step inputs.";
    };

    outputs_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/ace-step-1-5/outputs";
      description = "Host path for generated ACE-Step outputs.";
    };

    state_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/ace-step-1-5/state";
      description = "Host path for ACE-Step runtime state, caches, logs, and temporary files.";
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NVIDIA GPU scheduling for the ACE-Step pod.";
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
      description = "Optional node selector for the ACE-Step pod.";
    };

    tolerations = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "Optional Kubernetes tolerations for the ACE-Step pod.";
    };

    affinity = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Optional Kubernetes affinity for the ACE-Step pod.";
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
        "L+ /var/lib/rancher/k3s/server/manifests/10-ace-step-1-5-helmchart.yaml - - - - ${aceStepHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-ace-step-1-5-cert.yaml - - - - ${aceStepCert}"
        "d ${cfg.models_path} 0755 root root -"
        "d ${cfg.inputs_path} 0755 root root -"
        "d ${cfg.outputs_path} 0755 root root -"
        "d ${cfg.state_path} 0755 root root -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/10-ace-step-1-5-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-ace-step-1-5-cert.yaml"
      ];
    })
  ];
}
