{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.docling_serve;
  parent = config.extraServices.single_node_k3s;

  serviceName = "docling-serve";
  containerPort = 5001;

  manifestDir = "/var/lib/rancher/k3s/server/manifests";
  uninstallStateDir = "/var/lib/rancher/k3s/server/uninstalling-manifests/${serviceName}";

  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  doclingModelCachePv = pkgs.writeText "00-docling-serve-model-cache-pv.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: docling-serve-model-cache-pv
      labels:
        type: local
        app.kubernetes.io/name: docling-serve
    spec:
      storageClassName: base
      capacity:
        storage: ${cfg.modelCache.size}
      accessModes:
        - ${cfg.modelCache.accessMode}
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: ${cfg.modelCache.host_path}
  '';

  doclingCert = pkgs.writeText "20-docling-serve-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: docling-serve-tls
      namespace: default
    spec:
      secretName: docling-serve-tls-secret
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

  gpuResources = {
    limits = {
      "nvidia.com/gpu" = cfg.gpu.number;
      memory = cfg.gpu.memoryLimit;
    };
    requests = {
      "nvidia.com/gpu" = cfg.gpu.number;
      memory = cfg.gpu.memoryRequest;
    };
  };

  baseValues = {
    fullnameOverride = serviceName;
    replicaCount = cfg.replicaCount;

    image = {
      repository =
        if cfg.gpu.enable
        then cfg.gpu.imageRepository
        else cfg.image.repository;
      pullPolicy = cfg.image.pullPolicy;
      tag = cfg.image.tag;
    };

    computeEngine = {
      type = cfg.computeEngine;
    };

    device = {
      type =
        if cfg.gpu.enable
        then "cuda"
        else "cpu";
      cudaDevices = cfg.gpu.cudaDevices;
    };

    env = {
      uvicorn = {
        host = "0.0.0.0";
        port = containerPort;
        reload = false;
        workers = cfg.uvicornWorkers;
      };

      doclingServe = {
        enableUi = cfg.enableUi;
        enableRemoteServices = cfg.enableRemoteServices;
        singleUseResults = cfg.singleUseResults;
        maxDocumentTimeout = cfg.maxDocumentTimeout;
        loadModelsAtBoot = cfg.modelCache.loadModelsAtBoot;
      };

      doclingPerf = {
        numThreads = cfg.performance.numThreads;
        pageBatchSize = cfg.performance.pageBatchSize;
        elementsBatchSize = cfg.performance.elementsBatchSize;
      };

      custom = cfg.extraEnv;
    };

    modelCache = {
      enabled = cfg.modelCache.enable;
      storageClass = "base";
      size = cfg.modelCache.size;
      accessMode = cfg.modelCache.accessMode;
      mountPath = cfg.modelCache.mountPath;

      job = {
        enabled = cfg.modelCache.preload;
        ttlSecondsAfterFinished = cfg.modelCache.jobTtlSecondsAfterFinished;
        resources = cfg.modelCache.jobResources;
      };

      models = {
        all = cfg.modelCache.models.all;
        list = cfg.modelCache.models.list;
      };
    };

    service = {
      type = "ClusterIP";
      port = containerPort;
    };

    ingress = {
      enabled = true;
      className = "nginx";
      annotations = {
        "nginx.ingress.kubernetes.io/force-ssl-redirect" = "false";
        "nginx.ingress.kubernetes.io/ssl-redirect" = "false";
        "gethomepage.dev/enabled" = "true";
        "gethomepage.dev/group" = "AI";
        "gethomepage.dev/name" = "Docling Serve";
        "gethomepage.dev/description" = "Document conversion API powered by Docling.";
        "gethomepage.dev/icon" = "docling.png";
        "gethomepage.dev/href" = "https://${cfg.subdomain}.${parent.full_hostname}/ui";
        "gethomepage.dev/siteMonitor" = "http://${serviceName}.default.svc.cluster.local:${toString containerPort}/health";
      };
      hosts = [
        {
          host = "${cfg.subdomain}.${parent.full_hostname}";
          paths = [
            {
              path = "/";
              pathType = "Prefix";
            }
          ];
        }
        {
          host = "${cfg.subdomain}.${parent.node_master_ip}.nip.io";
          paths = [
            {
              path = "/";
              pathType = "Prefix";
            }
          ];
        }
      ];
      tls = [
        {
          secretName = "docling-serve-tls-secret"; # pragma: allowlist secret
          hosts = [
            "${cfg.subdomain}.${parent.full_hostname}"
            "${cfg.subdomain}.${parent.node_master_ip}.nip.io"
          ];
        }
      ];
    };

    resources =
      if cfg.gpu.enable
      then lib.recursiveUpdate cfg.resources gpuResources
      else cfg.resources;

    nodeSelector = cfg.nodeSelector;
    tolerations = cfg.tolerations;
    affinity = cfg.affinity;
  };

  values =
    baseValues
    // lib.optionalAttrs cfg.gpu.enable {
      runtimeClassName = cfg.gpu.runtimeClassName;
    };

  valuesYaml = lib.generators.toYAML {} values;

  doclingHelmChart = pkgs.writeText "10-docling-serve-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: docling-serve
      namespace: kube-system
    spec:
      repo: http://charts.mrsharky.com
      chart: docling-serve
      version: ${cfg.chart_version}
      targetNamespace: default
      valuesContent: |
    ${indent 4 valuesYaml}
  '';
in {
  options.extraServices.single_node_k3s.docling_serve = {
    enable = lib.mkEnableOption "Docling Serve service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "docling";
      example = "documents";
      description = "Subdomain prefix used for ingress.";
    };

    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "0.1.1";
      description = "Version of the Docling Serve Helm chart from charts.mrsharky.com.";
    };

    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of Docling Serve replicas.";
    };

    image = {
      repository = lib.mkOption {
        type = lib.types.str;
        default = "quay.io/docling-project/docling-serve-cpu";
        description = "CPU image repository for Docling Serve.";
      };

      tag = lib.mkOption {
        type = lib.types.str;
        default = "v1.9.0";
        description = "Docling Serve image tag.";
      };

      pullPolicy = lib.mkOption {
        type = lib.types.str;
        default = "IfNotPresent";
        description = "Container image pull policy.";
      };
    };

    computeEngine = lib.mkOption {
      type = lib.types.enum ["local" "rq"];
      default = "local";
      description = "Docling Serve compute engine: local synchronous processing or rq Redis Queue processing.";
    };

    enableUi = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the Docling Serve UI.";
    };

    enableRemoteServices = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Docling remote processing services.";
    };

    singleUseResults = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Expose conversion results for a single retrieval.";
    };

    maxDocumentTimeout = lib.mkOption {
      type = lib.types.int;
      default = 604800;
      description = "Maximum document processing timeout in seconds.";
    };

    uvicornWorkers = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of Uvicorn workers.";
    };

    performance = {
      numThreads = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Number of Docling processing threads.";
      };

      pageBatchSize = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Pages processed per batch.";
      };

      elementsBatchSize = lib.mkOption {
        type = lib.types.int;
        default = 8;
        description = "Elements processed per batch.";
      };
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable NVIDIA CUDA processing for Docling Serve.";
      };

      type = lib.mkOption {
        type = lib.types.enum ["nvidia"];
        default = "nvidia";
        description = "GPU type. The upstream Docling Serve chart currently documents CUDA/NVIDIA only.";
      };

      number = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of NVIDIA GPUs requested by the Docling Serve pod.";
      };

      cudaDevices = lib.mkOption {
        type = lib.types.str;
        default = "cuda:0";
        example = "cuda:0,cuda:1";
        description = "DOCLING_DEVICE value used when GPU processing is enabled.";
      };

      runtimeClassName = lib.mkOption {
        type = lib.types.str;
        default = "nvidia";
        description = "Kubernetes RuntimeClassName used when GPU processing is enabled.";
      };

      imageRepository = lib.mkOption {
        type = lib.types.str;
        default = "quay.io/docling-project/docling-serve-cu126";
        description = "CUDA image repository for Docling Serve.";
      };

      memoryRequest = lib.mkOption {
        type = lib.types.str;
        default = "8Gi";
        description = "Memory request used when GPU processing is enabled.";
      };

      memoryLimit = lib.mkOption {
        type = lib.types.str;
        default = "16Gi";
        description = "Memory limit used when GPU processing is enabled.";
      };
    };

    modelCache = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the Docling model-cache PVC.";
      };

      host_path = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/kube/data/docling-serve/modelcache";
        example = "/mnt/kube/data/docling-serve/modelcache";
        description = "Host path backing the Docling model-cache PV.";
      };

      size = lib.mkOption {
        type = lib.types.str;
        default = "80Gi";
        description = "Requested model-cache PVC size.";
      };

      accessMode = lib.mkOption {
        type = lib.types.str;
        default = "ReadWriteOnce";
        description = "Access mode for the model-cache PVC.";
      };

      mountPath = lib.mkOption {
        type = lib.types.str;
        default = "/modelcache";
        description = "Container mount path for the Docling model cache.";
      };

      preload = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the chart's model download job.";
      };

      loadModelsAtBoot = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Load Docling models during service startup. Keep false so the API can start before the async model download job completes.";
      };

      jobTtlSecondsAfterFinished = lib.mkOption {
        type = lib.types.int;
        default = 100;
        description = "TTL for the model download job after it finishes.";
      };

      jobResources = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Resource overrides for the model download job.";
      };

      models = {
        all = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Download all available Docling models into the model cache.";
        };

        list = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "layout"
            "tableformer"
            "picture_classifier"
            "rapidocr"
            "easyocr"
          ];
          example = ["layout" "tableformer" "picture_classifier" "rapidocr" "easyocr" "smolvlm"];
          description = "Specific Docling models to download into the model cache.";
        };
      };
    };

    resources = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      example = {
        limits = {
          cpu = "4000m";
          memory = "8Gi";
        };
        requests = {
          cpu = "2000m";
          memory = "4Gi";
        };
      };
      description = "Kubernetes resources passed to the Docling Serve container. GPU settings are merged in when gpu.enable is true.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.bool
      ]);
      default = {};
      example = {
        DOCLING_SERVE_MAX_SYNC_WAIT = 30;
      };
      description = "Additional custom environment variables for the Docling Serve container.";
    };

    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "kubernetes.io/hostname" = "gpu-node";
      };
      description = "Optional node selector.";
    };

    tolerations = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "Optional Kubernetes tolerations for the Docling Serve pod.";
    };

    affinity = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Optional Kubernetes affinity for the Docling Serve pod.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules =
        [
          "L+ /var/lib/rancher/k3s/server/manifests/10-docling-serve-helmchart.yaml - - - - ${doclingHelmChart}"
          "L+ /var/lib/rancher/k3s/server/manifests/20-docling-serve-cert.yaml - - - - ${doclingCert}"
        ]
        ++ lib.optionals cfg.modelCache.enable [
          "L+ /var/lib/rancher/k3s/server/manifests/00-docling-serve-model-cache-pv.yaml - - - - ${doclingModelCachePv}"
          "d ${cfg.modelCache.host_path} 0777 root root -"
        ];
    })

    (lib.mkIf (!cfg.enable) {
      systemd.services.uninstall-docling-serve = {
        description = "Uninstall Docling Serve from k3s";
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
            ! manifest_exists "${manifestDir}/10-docling-serve-helmchart.yaml" &&
            ! manifest_exists "${manifestDir}/20-docling-serve-cert.yaml" &&
            ! manifest_exists "${manifestDir}/00-docling-serve-model-cache-pv.yaml" &&
            ! staged_manifest_exists "10-docling-serve-helmchart.yaml" &&
            ! staged_manifest_exists "20-docling-serve-cert.yaml" &&
            ! staged_manifest_exists "00-docling-serve-model-cache-pv.yaml"
          then
            echo "No Docling Serve manifests found; skipping uninstall."
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

          stage_manifest "10-docling-serve-helmchart.yaml"
          stage_manifest "20-docling-serve-cert.yaml"
          stage_manifest "00-docling-serve-model-cache-pv.yaml"

          if staged_manifest_exists "10-docling-serve-helmchart.yaml"; then
            k3s kubectl -n kube-system delete addon 10-docling-serve-helmchart --ignore-not-found
            k3s kubectl -n kube-system delete helmchart ${serviceName} --ignore-not-found --wait=true --timeout=5m
            rm -f "${uninstallStateDir}/10-docling-serve-helmchart.yaml"
          fi

          if staged_manifest_exists "20-docling-serve-cert.yaml"; then
            k3s kubectl -n kube-system delete addon 20-docling-serve-cert --ignore-not-found
            k3s kubectl delete certificate docling-serve-tls --ignore-not-found
            k3s kubectl delete secret docling-serve-tls-secret --ignore-not-found
            rm -f "${uninstallStateDir}/20-docling-serve-cert.yaml"
          fi

          if staged_manifest_exists "00-docling-serve-model-cache-pv.yaml"; then
            k3s kubectl -n kube-system delete addon 00-docling-serve-model-cache-pv --ignore-not-found
            k3s kubectl delete pvc ${serviceName}-model-cache --ignore-not-found --wait=true --timeout=5m
            k3s kubectl delete pv ${serviceName}-model-cache-pv --ignore-not-found
            rm -f "${uninstallStateDir}/00-docling-serve-model-cache-pv.yaml"
          fi

          rmdir "${uninstallStateDir}" 2>/dev/null || true
        '';
      };
    })
  ];
}
