{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.ollama;
  parent = config.extraServices.single_node_k3s;

  # Helper method to indent strings
  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    # prefix first line, and after every newline
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  boolString = v:
    if v
    then "true"
    else "false";

  quoted = s: "\"${s}\"";

  renderYamlList = indentLevel: items:
    if items == []
    then " []"
    else "\n${indent indentLevel (lib.concatMapStringsSep "\n" (item: "- ${item}") items)}";

  renderExtraEnv = indentLevel: attrs: let
    names = builtins.attrNames attrs;
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") indentLevel);
  in
    if names == []
    then " []"
    else
      "\n"
      + lib.concatMapStringsSep "\n" (
        name:
          lib.concatStringsSep "\n" [
            "${pad}- name: ${name}"
            "${pad}  value: ${quoted (toString attrs.${name})}"
          ]
      )
      names;

  renderStringMap = indentLevel: attrs: let
    names = builtins.attrNames attrs;
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") indentLevel);
  in
    if names == []
    then " {}"
    else "\n" + lib.concatMapStringsSep "\n" (name: "${pad}${name}: ${quoted (toString attrs.${name})}") names;

  # -------------------------
  # PV + PVC for Ollama data
  # -------------------------
  ollamaPvPvc = pkgs.writeText "00-ollama-pv-pvc.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: ollama-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: ${cfg.size}
      accessModes:
        - ReadWriteOnce
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: ${cfg.host_path}
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ollama-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: ${cfg.size}
      volumeName: ollama-pv
  '';

  # -------------------------
  # cert-manager cert
  # -------------------------
  ollamaCert = pkgs.writeText "20-ollama-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: ollama-tls
      namespace: default
    spec:
      secretName: ollama-tls-secret
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

  # -------------------------
  # HelmChart (k3s helm-controller)
  # -------------------------
  ollamaHelmChart = pkgs.writeText "10-ollama-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: ollama
      namespace: kube-system
    spec:
      repo: https://helm.otwld.com/
      chart: ollama
      version: ${cfg.chart_version}
      targetNamespace: default
      valuesContent: |
        ollama:
          gpu:
            enabled: ${boolString cfg.gpu.enable}
            type: ${quoted cfg.gpu.type}
            number: ${toString cfg.gpu.number}

          models:
            pull:${renderYamlList 10 cfg.models.pull}
            run:${renderYamlList 10 cfg.models.run}
            clean: false

        ${lib.optionalString (cfg.gpu.enable && cfg.gpu.type == "nvidia") ''
      runtimeClassName: "nvidia"
    ''}

        ingress:
          enabled: true
          className: "nginx"
          annotations:
            nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
            nginx.ingress.kubernetes.io/ssl-redirect: "false"
            gethomepage.dev/enabled: "true"
            gethomepage.dev/group: "AI"
            gethomepage.dev/name: "Ollama"
            gethomepage.dev/description: "Local LLM inference server powered by Ollama."
            gethomepage.dev/icon: "ollama.png"
            gethomepage.dev/siteMonitor: "http://ollama.default.svc.cluster.local:11434"
          hosts:
            - host: ${cfg.subdomain}.${parent.full_hostname}
              paths:
                - path: /
                  pathType: Prefix
            - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
              paths:
                - path: /
                  pathType: Prefix
          tls:
            - secretName: ollama-tls-secret
              hosts:
                - ${cfg.subdomain}.${parent.full_hostname}
                - ${cfg.subdomain}.${parent.node_master_ip}.nip.io

        persistentVolume:
          enabled: true
          existingClaim: "ollama-pvc"
          size: ${cfg.size}
          storageClass: "base"
          volumeName: "ollama-pv"

        extraEnv:${renderExtraEnv 10 cfg.extraEnv}

        nodeSelector:${renderStringMap 10 cfg.nodeSelector}
  '';
in {
  options.extraServices.single_node_k3s.ollama = {
    enable = lib.mkEnableOption "Ollama service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "ollama";
      example = "llm";
      description = "Subdomain prefix used for ingress.";
    };

    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "1.49.0";
      description = "Version of the ollama Helm chart.";
    };

    host_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/data/ollama";
      example = "/mnt/kube/data/ollama";
      description = "Host path for Ollama persistent data.";
    };

    size = lib.mkOption {
      type = lib.types.str;
      default = "200Gi";
      example = "200Gi";
      description = "Requested PVC size for Ollama data.";
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable GPU integration.";
      };

      type = lib.mkOption {
        type = lib.types.enum ["nvidia" "amd"];
        default = "nvidia";
        description = "GPU type.";
      };

      number = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of GPUs.";
      };
    };

    models = {
      pull = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "deepcoder:14b"
          "deepseek-r1:32b"
          # "devstral:24b"
          # "gemma3:27b"
          # "gpt-oss:20b"
          "llama3.1:8b"
          #"llama3.2:3b"
          # "magistral:24b
          # "ministral-3:14b"
          # "mistral-small3.2:24b"
          # "olmo-3.1:32b"
          # "phi4-reasoning:14b"
          # "qwen2.5-coder:7b"
          # "qwen2.5vl:32b"
          # "qwen3:32b"
          "qwen3-coder:30b"
          "hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q4_K_XL"
          # "qwen3.5:9b"
          # "qwen3.5:27b"
        ];
        example = ["llama3.2" "nomic-embed-text"];
        description = "Models to pull at container startup.";
      };

      run = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["llama3.2"];
        description = "Models to load into memory at startup.";
      };
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.bool
      ]);
      default = {
        OLLAMA_KEEP_ALIVE = "3m";
      };
      example = {
        OLLAMA_KEEP_ALIVE = "24h";
        OLLAMA_NUM_PARALLEL = 2;
      };
      description = "Extra environment variables for the Ollama container.";
    };

    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "kubernetes.io/hostname" = "gpu-node";
      };
      description = "Optional node selector.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "L+ /var/lib/rancher/k3s/server/manifests/00-ollama-pv-pvc.yaml - - - - ${ollamaPvPvc}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-ollama-helmchart.yaml - - - - ${ollamaHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-ollama-cert.yaml - - - - ${ollamaCert}"
        "d ${cfg.host_path} 0755 root root -"
      ];
    })

    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        "r /var/lib/rancher/k3s/server/manifests/00-ollama-pv-pvc.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-ollama-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-ollama-cert.yaml"
      ];
    })
  ];
}
