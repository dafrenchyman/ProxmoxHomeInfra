{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.paddleocr_vl;
  parent = config.extraServices.single_node_k3s;

  serviceName = "paddleocr-vl";
  apiPort = 8080;

  manifestDir = "/var/lib/rancher/k3s/server/manifests";
  uninstallStateDir = "/var/lib/rancher/k3s/server/uninstalling-manifests/${serviceName}";

  indent = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
  in
    pad + builtins.replaceStrings ["\n"] ["\n${pad}"] s;

  mkHostPathPv = name: hostPath: size: accessMode:
    pkgs.writeText "00-${serviceName}-${name}-pv.yaml" ''
      apiVersion: v1
      kind: PersistentVolume
      metadata:
        name: ${serviceName}-${name}-pv
        labels:
          type: local
          app.kubernetes.io/name: ${serviceName}
      spec:
        storageClassName: base
        capacity:
          storage: ${size}
        accessModes:
          - ${accessMode}
        persistentVolumeReclaimPolicy: Retain
        hostPath:
          path: ${hostPath}
    '';

  pipelineCachePv = mkHostPathPv "pipeline-cache" cfg.pipelineCache.host_path cfg.pipelineCache.size cfg.pipelineCache.accessMode;
  vlmCachePv = mkHostPathPv "vlm-cache" cfg.vlmCache.host_path cfg.vlmCache.size cfg.vlmCache.accessMode;
  runtimeStatePv = mkHostPathPv "runtime-state" cfg.runtimeState.host_path cfg.runtimeState.size cfg.runtimeState.accessMode;

  paddleocrCert = pkgs.writeText "00-${serviceName}-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: ${serviceName}-tls
      namespace: default
    spec:
      secretName: ${serviceName}-tls-secret
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

  gpuResource = lib.optionalAttrs cfg.gpu.enable {
    "nvidia.com/gpu" = cfg.gpu.count;
  };

  resources = {
    api = cfg.resources.api;
    pipeline =
      lib.recursiveUpdate {
        requests =
          {
            cpu = cfg.pipeline.resources.cpuRequest;
            memory = cfg.pipeline.resources.memoryRequest;
          }
          // gpuResource;
        limits =
          {
            memory = cfg.pipeline.resources.memoryLimit;
          }
          // gpuResource;
      }
      cfg.resources.pipeline;
    vlm =
      lib.recursiveUpdate {
        requests =
          {
            cpu = cfg.vlm.resources.cpuRequest;
            memory = cfg.vlm.resources.memoryRequest;
          }
          // gpuResource;
        limits =
          {
            memory = cfg.vlm.resources.memoryLimit;
          }
          // gpuResource;
      }
      cfg.resources.vlm;
  };

  baseValues = {
    fullnameOverride = serviceName;

    image = {
      api = cfg.image.api;
      pipeline = cfg.image.pipeline;
      vlm = cfg.image.vlm;
    };

    paddleocr = {
      pipelineName = cfg.paddleocr.pipelineName;
      paddlexVersion = cfg.paddleocr.paddlexVersion;
      sdkDir = cfg.paddleocr.sdkDir;
      vlmName = cfg.paddleocr.vlmName;
      modelSource = cfg.paddleocr.modelSource;
      disableModelSourceCheck = cfg.paddleocr.disableModelSourceCheck;
      replicas = {
        api = cfg.replicas.api;
        pipeline = cfg.replicas.pipeline;
        vlm = cfg.replicas.vlm;
      };
    };

    serving = cfg.serving;

    gpu = {
      deviceId = cfg.gpu.deviceId;
      nvidiaVisibleDevices = cfg.gpu.nvidiaVisibleDevices;
      driverCapabilities = cfg.gpu.driverCapabilities;
      tritonLibcudaPath = cfg.gpu.tritonLibcudaPath;
    };

    runtimeClassName =
      if cfg.gpu.enable
      then cfg.gpu.runtimeClassName
      else "";

    vlm = {
      backend = cfg.vlm.backend;
      modelDir = cfg.vlm.modelDir;
      backendConfig = cfg.vlm.backendConfig;
      extraArgs = cfg.vlm.extraArgs;
      sleepMode = cfg.vlm.sleepMode;
    };

    resources = resources;

    service = {
      api = {
        enabled = true;
        controller = "api";
        type = "ClusterIP";
        ports.http = {
          port = apiPort;
          targetPort = "http";
          protocol = "TCP";
        };
      };
      pipeline = {
        enabled = true;
        controller = "pipeline";
        type = "ClusterIP";
        ports = {
          http = {
            port = 8000;
            targetPort = "http";
            protocol = "TCP";
          };
          grpc = {
            port = 8001;
            targetPort = "grpc";
            protocol = "TCP";
          };
        };
      };
      vlm = {
        enabled = true;
        controller = "vlm";
        type = "ClusterIP";
        ports.http = {
          port = 8080;
          targetPort = "http";
          protocol = "TCP";
        };
      };
    };

    ingress.api = {
      enabled = true;
      className = "nginx";
      annotations = {
        "nginx.ingress.kubernetes.io/force-ssl-redirect" = "false";
        "nginx.ingress.kubernetes.io/ssl-redirect" = "false";
        "gethomepage.dev/enabled" = "true";
        "gethomepage.dev/group" = "AI";
        "gethomepage.dev/name" = "PaddleOCR-VL";
        "gethomepage.dev/description" = "High-performance PaddleOCR-VL document parsing API.";
        "gethomepage.dev/icon" = "mdi-text-recognition";
        "gethomepage.dev/href" = "https://${cfg.subdomain}.${parent.full_hostname}";
        "gethomepage.dev/siteMonitor" = "http://${serviceName}.default.svc.cluster.local:${toString apiPort}/health";
      };
      hosts = [
        {
          host = "${cfg.subdomain}.${parent.full_hostname}";
          paths = [
            {
              path = "/";
              pathType = "Prefix";
              service = {
                identifier = "api";
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
                identifier = "api";
                port = "http";
              };
            }
          ];
        }
      ];
      tls = [
        {
          secretName = "${serviceName}-tls-secret";
          hosts = [
            "${cfg.subdomain}.${parent.full_hostname}"
            "${cfg.subdomain}.${parent.node_master_ip}.nip.io"
          ];
        }
      ];
    };

    persistence = {
      "pipeline-cache" = {
        enabled = cfg.pipelineCache.enable;
        type = "persistentVolumeClaim";
        storageClass = "base";
        accessMode = cfg.pipelineCache.accessMode;
        size = cfg.pipelineCache.size;
        advancedMounts.pipeline.app = [
          {
            path = "/cache";
            readOnly = false;
          }
        ];
      };

      "pipeline-shm" = {
        enabled = true;
        type = "emptyDir";
        medium = "Memory";
        sizeLimit = cfg.pipeline.sharedMemorySize;
        advancedMounts.pipeline.app = [
          {
            path = "/dev/shm";
            readOnly = false;
          }
        ];
      };

      "vlm-cache" = {
        enabled = cfg.vlmCache.enable;
        type = "persistentVolumeClaim";
        storageClass = "base";
        accessMode = cfg.vlmCache.accessMode;
        size = cfg.vlmCache.size;
        advancedMounts.vlm.app = [
          {
            path = "/cache";
            readOnly = false;
          }
        ];
      };

      "vlm-shm" = {
        enabled = true;
        type = "emptyDir";
        medium = "Memory";
        sizeLimit = cfg.vlm.sharedMemorySize;
        advancedMounts.vlm.app = [
          {
            path = "/dev/shm";
            readOnly = false;
          }
        ];
      };

      "runtime-state" = {
        enabled = cfg.runtimeState.enable;
        type = "persistentVolumeClaim";
        storageClass = "base";
        accessMode = cfg.runtimeState.accessMode;
        size = cfg.runtimeState.size;
        advancedMounts = {
          api.app = [
            {
              path = "/state";
              readOnly = false;
            }
          ];
          pipeline.app = [
            {
              path = "/state";
              readOnly = false;
            }
          ];
          vlm.app = [
            {
              path = "/state";
              readOnly = false;
            }
          ];
        };
      };
    };

    podSecurityContext = cfg.podSecurityContext;
    containerSecurityContext = cfg.containerSecurityContext;
    nodeSelector = cfg.nodeSelector;
    tolerations = cfg.tolerations;
    affinity = cfg.affinity;
    defaultPodOptions = cfg.defaultPodOptions;
    controllers = cfg.controllers;
  };

  values = lib.recursiveUpdate baseValues cfg.extraValues;
  valuesYaml = lib.generators.toYAML {} values;

  paddleocrHelmChart = pkgs.writeText "10-${serviceName}-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: ${serviceName}
      namespace: kube-system
    spec:
      repo: https://charts.mrsharky.com
      chart: paddleocr-vl
      version: ${cfg.chart_version}
      targetNamespace: default
      valuesContent: |
    ${indent 4 valuesYaml}
  '';
in {
  options.extraServices.single_node_k3s.paddleocr_vl = {
    enable = lib.mkEnableOption "PaddleOCR-VL service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "paddleocr";
      example = "ocr";
      description = "Subdomain prefix used for ingress.";
    };

    chart_version = lib.mkOption {
      type = lib.types.str;
      default = "0.1.0";
      description = "Version of the PaddleOCR-VL Helm chart from charts.mrsharky.com.";
    };

    image = {
      api = {
        repository = lib.mkOption {
          type = lib.types.str;
          default = "ghcr.io/dafrenchyman/paddleocr-vl-gateway";
          description = "PaddleOCR-VL API gateway image repository.";
        };
        tag = lib.mkOption {
          type = lib.types.str;
          default = "latest";
          description = "PaddleOCR-VL API gateway image tag.";
        };
        pullPolicy = lib.mkOption {
          type = lib.types.str;
          default = "IfNotPresent";
          description = "PaddleOCR-VL API gateway image pull policy.";
        };
      };

      pipeline = {
        repository = lib.mkOption {
          type = lib.types.str;
          default = "ghcr.io/dafrenchyman/paddleocr-vl-pipeline";
          description = "PaddleOCR-VL Triton pipeline image repository.";
        };
        tag = lib.mkOption {
          type = lib.types.str;
          default = "latest";
          description = "PaddleOCR-VL Triton pipeline image tag.";
        };
        pullPolicy = lib.mkOption {
          type = lib.types.str;
          default = "IfNotPresent";
          description = "PaddleOCR-VL Triton pipeline image pull policy.";
        };
      };

      vlm = {
        repository = lib.mkOption {
          type = lib.types.str;
          default = "ccr-2vdh3abv-pub.cnc.bj.baidubce.com/paddlepaddle/paddleocr-genai-vllm-server";
          description = "PaddleOCR-VL generative VLM server image repository.";
        };
        tag = lib.mkOption {
          type = lib.types.str;
          default = "latest-nvidia-gpu@sha256:5713fd30ab76094b7b6a20d95fd8e26fa9dc452bcc90ccb16f1fb056bd2a0f4d";
          description = "PaddleOCR-VL generative VLM server image tag or digest.";
        };
        pullPolicy = lib.mkOption {
          type = lib.types.str;
          default = "IfNotPresent";
          description = "PaddleOCR-VL VLM server image pull policy.";
        };
      };
    };

    replicas = {
      api = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of API gateway replicas.";
      };
      pipeline = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of Triton pipeline replicas.";
      };
      vlm = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of VLM server replicas.";
      };
    };

    paddleocr = {
      pipelineName = lib.mkOption {
        type = lib.types.str;
        default = "PaddleOCR-VL-1.6";
        description = "PaddleOCR-VL pipeline release.";
      };
      paddlexVersion = lib.mkOption {
        type = lib.types.str;
        default = "3.6";
        description = "PaddleX HPS SDK/base-image major.minor version.";
      };
      sdkDir = lib.mkOption {
        type = lib.types.str;
        default = "paddlex_hps_PaddleOCR-VL-1.6_sdk";
        description = "PaddleX HPS SDK directory name.";
      };
      vlmName = lib.mkOption {
        type = lib.types.str;
        default = "PaddleOCR-VL-1.6-0.9B";
        description = "PaddleOCR-VL VLM model name.";
      };
      modelSource = lib.mkOption {
        type = lib.types.enum ["huggingface" "aistudio" "modelscope" "bos"];
        default = "huggingface";
        description = "PaddleX model source.";
      };
      disableModelSourceCheck = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Disable PaddleX model source reachability checks.";
      };
    };

    serving = lib.mkOption {
      type = lib.types.attrs;
      default = {
        maxConcurrentInferenceRequests = 16;
        maxConcurrentNonInferenceRequests = 64;
        inferenceTimeoutSeconds = 600;
        healthCheckTimeoutSeconds = 5;
        logLevel = "INFO";
        filterHealthAccessLog = true;
        uvicornWorkers = 4;
      };
      description = "Gateway serving settings passed to the chart.";
    };

    gpu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NVIDIA GPU scheduling for the pipeline and VLM pods.";
      };
      count = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of nvidia.com/gpu scheduler slots requested by each GPU pod.";
      };
      deviceId = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "HPS_DEVICE_ID passed to GPU containers.";
      };
      nvidiaVisibleDevices = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = "NVIDIA_VISIBLE_DEVICES passed to GPU containers.";
      };
      driverCapabilities = lib.mkOption {
        type = lib.types.str;
        default = "compute,utility";
        description = "NVIDIA_DRIVER_CAPABILITIES passed to GPU containers.";
      };
      tritonLibcudaPath = lib.mkOption {
        type = lib.types.str;
        default = "/usr/lib/x86_64-linux-gnu";
        description = "TRITON_LIBCUDA_PATH for Triton/vLLM CUDA library discovery on the NixOS NVIDIA runtime.";
      };
      runtimeClassName = lib.mkOption {
        type = lib.types.str;
        default = "nvidia";
        description = "Kubernetes RuntimeClassName used by the GPU pods.";
      };
    };

    pipeline.resources = {
      cpuRequest = lib.mkOption {
        type = lib.types.str;
        default = "1000m";
        description = "CPU request for the Triton pipeline pod.";
      };
      memoryRequest = lib.mkOption {
        type = lib.types.str;
        default = "8Gi";
        description = "Memory request for the Triton pipeline pod.";
      };
      memoryLimit = lib.mkOption {
        type = lib.types.str;
        default = "16Gi";
        description = "Memory limit for the Triton pipeline pod.";
      };
    };

    pipeline.sharedMemorySize = lib.mkOption {
      type = lib.types.str;
      default = "1Gi";
      description = "Memory-backed /dev/shm size for the Triton pipeline pod.";
    };

    vlm = {
      backend = lib.mkOption {
        type = lib.types.enum ["vllm" "sglang" "fastdeploy"];
        default = "vllm";
        description = "Backend passed to paddleocr genai_server.";
      };
      modelDir = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Optional local VLM model directory.";
      };
      backendConfig = lib.mkOption {
        type = lib.types.attrs;
        default = {
          "gpu-memory-utilization" = null;
          "max-num-seqs" = null;
        };
        description = "Optional generated VLM backend config.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra args appended to paddleocr genai_server.";
      };
      sleepMode = lib.mkOption {
        type = lib.types.attrs;
        default = {
          enabled = false;
          devMode = true;
        };
        description = "VLM sleep-mode settings.";
      };
      resources = {
        cpuRequest = lib.mkOption {
          type = lib.types.str;
          default = "1000m";
          description = "CPU request for the VLM pod.";
        };
        memoryRequest = lib.mkOption {
          type = lib.types.str;
          default = "8Gi";
          description = "Memory request for the VLM pod.";
        };
        memoryLimit = lib.mkOption {
          type = lib.types.str;
          default = "24Gi";
          description = "Memory limit for the VLM pod.";
        };
      };
      sharedMemorySize = lib.mkOption {
        type = lib.types.str;
        default = "1Gi";
        description = "Memory-backed /dev/shm size for the VLM pod.";
      };
    };

    pipelineCache = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the pipeline cache PVC.";
      };
      host_path = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/kube/data/paddleocr-vl/pipeline-cache";
        description = "Host path backing the pipeline cache PV.";
      };
      size = lib.mkOption {
        type = lib.types.str;
        default = "50Gi";
        description = "Requested pipeline cache PVC size.";
      };
      accessMode = lib.mkOption {
        type = lib.types.str;
        default = "ReadWriteOnce";
        description = "Access mode for the pipeline cache PVC.";
      };
    };

    vlmCache = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the VLM cache PVC.";
      };
      host_path = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/kube/data/paddleocr-vl/vlm-cache";
        description = "Host path backing the VLM cache PV.";
      };
      size = lib.mkOption {
        type = lib.types.str;
        default = "100Gi";
        description = "Requested VLM cache PVC size.";
      };
      accessMode = lib.mkOption {
        type = lib.types.str;
        default = "ReadWriteOnce";
        description = "Access mode for the VLM cache PVC.";
      };
    };

    runtimeState = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable a runtime-state PVC mounted at /state.";
      };
      host_path = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/kube/data/paddleocr-vl/runtime-state";
        description = "Host path backing the runtime-state PV.";
      };
      size = lib.mkOption {
        type = lib.types.str;
        default = "20Gi";
        description = "Requested runtime-state PVC size.";
      };
      accessMode = lib.mkOption {
        type = lib.types.str;
        default = "ReadWriteOnce";
        description = "Access mode for the runtime-state PVC.";
      };
    };

    podSecurityContext = lib.mkOption {
      type = lib.types.attrs;
      default = {
        fsGroup = 1000;
        fsGroupChangePolicy = "OnRootMismatch";
      };
      description = "Pod security context passed to the chart.";
    };

    containerSecurityContext = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Container security context passed to the chart.";
    };

    resources = {
      api = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Resource overrides for the API gateway pod.";
      };
      pipeline = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Resource overrides merged into the Triton pipeline pod resources.";
      };
      vlm = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Resource overrides merged into the VLM pod resources.";
      };
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
      description = "Optional Kubernetes tolerations.";
    };

    affinity = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Optional Kubernetes affinity.";
    };

    defaultPodOptions = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Optional bjw-s common defaultPodOptions override.";
    };

    controllers = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Optional bjw-s common controller overrides.";
    };

    extraValues = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Additional Helm values recursively merged into the generated PaddleOCR-VL values.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules =
        [
          "L+ /var/lib/rancher/k3s/server/manifests/00-${serviceName}-cert.yaml - - - - ${paddleocrCert}"
          "L+ /var/lib/rancher/k3s/server/manifests/10-${serviceName}-helmchart.yaml - - - - ${paddleocrHelmChart}"
        ]
        ++ lib.optionals cfg.pipelineCache.enable [
          "L+ /var/lib/rancher/k3s/server/manifests/00-${serviceName}-pipeline-cache-pv.yaml - - - - ${pipelineCachePv}"
          "d ${cfg.pipelineCache.host_path} 0777 root root -"
        ]
        ++ lib.optionals cfg.vlmCache.enable [
          "L+ /var/lib/rancher/k3s/server/manifests/00-${serviceName}-vlm-cache-pv.yaml - - - - ${vlmCachePv}"
          "d ${cfg.vlmCache.host_path} 0777 root root -"
        ]
        ++ lib.optionals cfg.runtimeState.enable [
          "L+ /var/lib/rancher/k3s/server/manifests/00-${serviceName}-runtime-state-pv.yaml - - - - ${runtimeStatePv}"
          "d ${cfg.runtimeState.host_path} 0777 root root -"
        ];
    })

    (lib.mkIf (!cfg.enable) {
      systemd.services.uninstall-paddleocr-vl = {
        description = "Uninstall PaddleOCR-VL from k3s";
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
            ! manifest_exists "${manifestDir}/10-${serviceName}-helmchart.yaml" &&
            ! manifest_exists "${manifestDir}/00-${serviceName}-cert.yaml" &&
            ! manifest_exists "${manifestDir}/00-${serviceName}-pipeline-cache-pv.yaml" &&
            ! manifest_exists "${manifestDir}/00-${serviceName}-vlm-cache-pv.yaml" &&
            ! manifest_exists "${manifestDir}/00-${serviceName}-runtime-state-pv.yaml" &&
            ! staged_manifest_exists "10-${serviceName}-helmchart.yaml" &&
            ! staged_manifest_exists "00-${serviceName}-cert.yaml" &&
            ! staged_manifest_exists "00-${serviceName}-pipeline-cache-pv.yaml" &&
            ! staged_manifest_exists "00-${serviceName}-vlm-cache-pv.yaml" &&
            ! staged_manifest_exists "00-${serviceName}-runtime-state-pv.yaml"
          then
            echo "No PaddleOCR-VL manifests found; skipping uninstall."
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

          stage_manifest "10-${serviceName}-helmchart.yaml"
          stage_manifest "00-${serviceName}-cert.yaml"
          stage_manifest "00-${serviceName}-pipeline-cache-pv.yaml"
          stage_manifest "00-${serviceName}-vlm-cache-pv.yaml"
          stage_manifest "00-${serviceName}-runtime-state-pv.yaml"

          if staged_manifest_exists "10-${serviceName}-helmchart.yaml"; then
            k3s kubectl -n kube-system delete addon 10-${serviceName}-helmchart --ignore-not-found
            k3s kubectl -n kube-system delete helmchart ${serviceName} --ignore-not-found --wait=true --timeout=5m
            rm -f "${uninstallStateDir}/10-${serviceName}-helmchart.yaml"
          fi

          if staged_manifest_exists "00-${serviceName}-cert.yaml"; then
            k3s kubectl -n kube-system delete addon 00-${serviceName}-cert --ignore-not-found
            k3s kubectl delete certificate ${serviceName}-tls --ignore-not-found
            k3s kubectl delete secret ${serviceName}-tls-secret --ignore-not-found
            rm -f "${uninstallStateDir}/00-${serviceName}-cert.yaml"
          fi

          if staged_manifest_exists "00-${serviceName}-pipeline-cache-pv.yaml"; then
            k3s kubectl -n kube-system delete addon 00-${serviceName}-pipeline-cache-pv --ignore-not-found
            k3s kubectl delete pvc ${serviceName}-pipeline-cache --ignore-not-found --wait=true --timeout=5m
            k3s kubectl delete pv ${serviceName}-pipeline-cache-pv --ignore-not-found
            rm -f "${uninstallStateDir}/00-${serviceName}-pipeline-cache-pv.yaml"
          fi

          if staged_manifest_exists "00-${serviceName}-vlm-cache-pv.yaml"; then
            k3s kubectl -n kube-system delete addon 00-${serviceName}-vlm-cache-pv --ignore-not-found
            k3s kubectl delete pvc ${serviceName}-vlm-cache --ignore-not-found --wait=true --timeout=5m
            k3s kubectl delete pv ${serviceName}-vlm-cache-pv --ignore-not-found
            rm -f "${uninstallStateDir}/00-${serviceName}-vlm-cache-pv.yaml"
          fi

          if staged_manifest_exists "00-${serviceName}-runtime-state-pv.yaml"; then
            k3s kubectl -n kube-system delete addon 00-${serviceName}-runtime-state-pv --ignore-not-found
            k3s kubectl delete pvc ${serviceName}-runtime-state --ignore-not-found --wait=true --timeout=5m
            k3s kubectl delete pv ${serviceName}-runtime-state-pv --ignore-not-found
            rm -f "${uninstallStateDir}/00-${serviceName}-runtime-state-pv.yaml"
          fi

          rmdir "${uninstallStateDir}" 2>/dev/null || true
        '';
      };
    })
  ];
}
