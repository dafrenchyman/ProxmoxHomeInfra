{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.openwebui;
  parent = config.extraServices.single_node_k3s;

  # PV/PVC to persist /app/data (users, hosts, settings)
  openwebuiPVs = pkgs.writeText "00-openwebui-pvs.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: openwebui-config-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 100Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.config_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: openwebui-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 100Gi
      volumeName: openwebui-config-pv
  '';

  ##########################################################################
  # cert-manager Certificate for Open WebUI ingress
  ##########################################################################
  openWebUICert = pkgs.writeText "20-openwebui-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: openwebui-tls
      namespace: default
    spec:
      secretName: openwebui-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.subdomain}.${parent.full_hostname}
        - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h    # 90 days
      renewBefore: 360h  # 15 days before expiration
  '';

  ##########################################################################
  # Optional: separate Ollama HelmChart (only used when embeddedOllama = false)
  ##########################################################################
  ollamaHelmChart = pkgs.writeText "05-ollama-helmchart.yaml" ''
        apiVersion: helm.cattle.io/v1
        kind: HelmChart
        metadata:
          name: ollama
          namespace: kube-system
        spec:
          repo: https://otwld.github.io/ollama-helm/
          chart: ollama
          version: ${cfg.ollama_chart_version}
          targetNamespace: default
          valuesContent: |
            ollama:
              gpu:
                enabled: ${
      if cfg.ollama_gpu_enable
      then "true"
      else "false"
    }
                type: ${lib.escapeShellArg cfg.ollama_gpu_type}
                number: ${toString cfg.ollama_gpu_number}

              # Pull models at container startup (ollama-helm supports this)
              # Example shown in ollama-helm docs.
              models:
                pull:
    ${lib.concatStringsSep "\n" (map (m: "              - " + m) cfg.ollama_models_pull)}

            # Optional scheduling controls (handy if only one node has GPU)
            ${lib.optionalString (cfg.ollama_runtimeClassName != null) ''
      runtimeClassName: ${cfg.ollama_runtimeClassName}
    ''}

            ${lib.optionalString (cfg.ollama_nodeSelector != {}) ''
              nodeSelector:
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "          ${k}: ${lib.escapeShellArg v}") cfg.ollama_nodeSelector)}
    ''}

            ${lib.optionalString (cfg.ollama_tolerations != []) ''
              tolerations:
      ${lib.concatStringsSep "\n" (map (t: "          - " + t) cfg.ollama_tolerations)}
    ''}
  '';

  ##########################################################################
  # Open WebUI HelmChart
  #
  # Key behavior:
  # - The Open WebUI chart can optionally install Ollama (embedded mode). :contentReference[oaicite:5]{index=5}
  # - Or you can set ollamaUrls to point to an existing Ollama service. :contentReference[oaicite:6]{index=6}
  ##########################################################################
  openWebUIHelmChart = pkgs.writeText "10-openwebui-helmchart.yaml" ''
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: open-webui
        namespace: kube-system
      spec:
        repo: https://open-webui.github.io/helm-charts
        chart: open-webui
        version: ${cfg.openwebui_chart_version}
        targetNamespace: default
        valuesContent: |
          ingress:
            enabled: true
            class: nginx
            annotations:
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              gethomepage.dev/enabled: "true"
              gethomepage.dev/group: Artificial Intelligence
              gethomepage.dev/name: Open WebUI
              gethomepage.dev/description: An extensible, feature-rich, and user-friendly self-hosted AI platform designed to operate entirely offline
              gethomepage.dev/icon: open-webui.png
              gethomepage.dev/siteMonitor: http://chat.default.svc.cluster.local:8080
            host: ${cfg.subdomain}.${parent.full_hostname}
            additionalHosts:
              - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
            hosts:
              - host: ${cfg.subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    pathType: Prefix
              - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    pathType: Prefix
            tls: true
            existingSecret: openwebui-tls-secret

          podSecurityContext:
            fsGroup: ${toString cfg.gid}
          containerSecurityContext:
            runAsUser: ${toString cfg.uid}
            runAsGroup: ${toString cfg.gid}

          persistence:
            enabled: true
            existingClaim: openwebui-config-pvc

          # External Ollama
          ollama:
            enabled: false
          ollamaUrls:
    ${lib.concatStringsSep "\n" (map (u: "        - " + u) cfg.ollama_urls)}
  '';
in {
  options.extraServices.single_node_k3s.openwebui = {
    enable = lib.mkEnableOption "Open WebUI (Helm) + Ollama (embedded or external)";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "chat";
      example = "chat";
      description = "Subdomain prefix used for the Open WebUI ingress (e.g. ai.example.com).";
    };

    # Open WebUI chart config
    openwebui_chart_version = lib.mkOption {
      type = lib.types.str;
      default = "12.3.0";
      description = "Open WebUI chart version to install (pin for reproducibility).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/kube/config/openwebui";
      example = "/mnt/kube/config/openwebui";
      description = "Host path used to persist /app/data.";
    };

    # Storage / persistence (kept simple; PVC-based)
    storageClass = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "local-path";
      description = "Optional storageClass for Open WebUI PVC. null means chart/default.";
    };

    persistenceSize = lib.mkOption {
      type = lib.types.str;
      default = "10Gi";
      description = "PVC size for Open WebUI data.";
    };

    # Embedded vs external Ollama
    embeddedOllama = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If true, Open WebUI chart will install Ollama as an optional dependency. :contentReference[oaicite:10]{index=10}
        If false, this module installs ollama-helm separately and sets open-webui.ollamaUrls. :contentReference[oaicite:11]{index=11}
      '';
    };

    embeddedOllamaName = lib.mkOption {
      type = lib.types.str;
      default = "open-webui-ollama";
      description = "fullnameOverride for embedded Ollama release (helps avoid naming collisions).";
    };

    # External ollama URLs (only used when embeddedOllama=false)
    ollama_urls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["http://ollama.default.svc.cluster.local:11434"];
      description = "List of Ollama API endpoints for Open WebUI when not embedding Ollama. :contentReference[oaicite:12]{index=12}";
    };

    ollama_chart_version = lib.mkOption {
      type = lib.types.str;
      default = "0.44.0";
      description = "Ollama Helm chart version to install (pin for reproducibility).";
    };

    ollama_models_pull = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["llama3.1:8b"];
      example = ["llama3.1:8b" "qwen2.5-coder:7b"];
      description = "Models to pull at container startup (ollama-helm supports this). :contentReference[oaicite:13]{index=13}";
    };

    ollama_gpu_enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable GPU in ollama-helm values. :contentReference[oaicite:14]{index=14}";
    };

    ollama_gpu_type = lib.mkOption {
      type = lib.types.str;
      default = "nvidia";
      description = "GPU type for ollama-helm (typically 'nvidia'). :contentReference[oaicite:15]{index=15}";
    };

    ollama_gpu_number = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of GPUs to allocate to Ollama.";
    };

    # Scheduling knobs for the Ollama pod (useful if only one node has the GPU)
    ollama_runtimeClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nvidia";
      description = "Optional runtimeClassName for GPU scheduling (cluster-dependent).";
    };

    ollama_nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {"kubernetes.io/hostname" = "gpu-node-1";};
      description = "Optional nodeSelector for Ollama.";
    };

    # This is intentionally “raw YAML fragments” to avoid over-modeling tolerations.
    ollama_tolerations = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [
        ''key: "nvidia.com/gpu", operator: "Exists", effect: "NoSchedule"''
      ];
      description = "Optional tolerations YAML fragments for Ollama pod.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "User id that accesses host-mounted folders.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "Group id that accesses host-mounted folders.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Ensure namespace exists (k3s will apply this if present as a manifest).
      # If you already manage namespaces elsewhere, you can remove this.
      systemd.tmpfiles.rules = [
        # If NOT embedding Ollama, install Ollama chart separately
        #${lib.optionalString (!cfg.embeddedOllama)
        #  "L+ /var/lib/rancher/k3s/server/manifests/05-ollama-helmchart.yaml - - - - ${ollamaHelmChart}"}
        "L+ /var/lib/rancher/k3s/server/manifests/00-openwebui-pvs.yaml - - - - ${openwebuiPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-openwebui-helmchart.yaml - - - - ${openWebUIHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-openwebui-cert.yaml - - - - ${openWebUICert}"

        "d ${cfg.config_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })

    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        #"r /var/lib/rancher/k3s/server/manifests/05-ollama-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/00-openwebui-pvs.yaml"
        "r /var/lib/rancher/k3s/server/manifests/10-openwebui-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-openwebui-cert.yaml"
      ];
    })
  ];
}
