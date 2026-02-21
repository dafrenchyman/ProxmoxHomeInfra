{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.ollama;
in {
  options.extraServices.ollama = {
    enable = lib.mkEnableOption "Ollama";

    ollamaHost = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Host/interface Ollama binds to.";
    };

    ollamaPort = lib.mkOption {
      type = lib.types.port;
      default = 11434;
      description = "Port Ollama listens on.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to open firewall ports for WebUI and Ollama.";
    };

    # Data locations
    ollamaDataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/ollama";
      description = "Persistent directory for Ollama models.";
    };

    # If you want to pre-pull some ollama models at activation time (optional)
    preloadModels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "deepcoder:14b"
        "deepseek-r1:32b"
        "devstral:24b"
        "gemma3:27b"
        "gpt-oss:20b"
        "llama3.1:8b"
        "llama3.2:3b"
        "magistral:24b"
        "ministral-3:14b"
        "mistral-small3.2:24b"
        "olmo-3.1:32b"
        "phi4-reasoning:14b"
        "qwen2.5-coder:7b"
        "qwen2.5vl:32b"
        "qwen3:32b"
        "qwen3-coder:30b"
      ];
      example = [
        "deepcoder:14b"
        "deepseek-r1:32b"
        "devstral:24b"
        "gemma3:27b"
        "gpt-oss:20b"
        "llama3.1:8b"
        "llama3.2:3b"
        "magistral:24b"
        "ministral-3:14b"
        "mistral-small3.2:24b"
        "olmo-3.1:32b"
        "phi4-reasoning:14b"
        "qwen2.5-coder:7b"
        "qwen2.5vl:32b"
        "qwen3:32b"
        "qwen3-coder:30b"
      ];
      description = "Ollama model names to pull during activation (best-effort).";
    };
  };

  config = lib.mkIf cfg.enable {
    ##########################################################################
    # Ollama (host service)
    ##########################################################################
    # Basic service enable
    services.ollama = {
      enable = true;
      package = lib.mkForce pkgs.ollama-cuda;

      loadModels = [
        "llama3.1:8b"
        "qwen2.5-coder:7b"
      ];

      # Bind to the chosen interface/port
      host = cfg.ollamaHost;
      port = cfg.ollamaPort;
    };

    systemd.services.ollama.environment = {
      LD_LIBRARY_PATH = "/run/opengl-driver/lib:/run/opengl-driver-32/lib";
      # Make Ollama prefer CUDA backend explicitly
      OLLAMA_LLM_LIBRARY = "cuda";
      # Optional: helps debugging
      OLLAMA_DEBUG = "INFO";
    };
    # GPU
    services.xserver.videoDrivers = ["nvidia"];
    hardware.nvidia.modesetting.enable = true;
    hardware.opengl.enable = true; # (or hardware.graphics.enable on newer nixpkgs)

    systemd.services.ollama.serviceConfig.SupplementaryGroups = lib.mkDefault [
      "render"
      "video"
    ];

    systemd.services.ollama.serviceConfig.ExecStart = lib.mkForce [
      ""
      "${pkgs.ollama-cuda}/bin/ollama serve"
    ];

    ##########################################################################
    # Firewall
    ##########################################################################
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      cfg.ollamaPort
    ];

    ##########################################################################
    # Directories
    ##########################################################################
    systemd.tmpfiles.rules = [
      "d ${cfg.ollamaDataDir} 0755 root root -"
    ];

    ##########################################################################
    # Optional model preload (best-effort)
    ##########################################################################
    # This runs after ollama is up and pulls models once per activation.
    # If you don’t want it, leave preloadModels = [].
    systemd.services.ollama-preload-models = lib.mkIf (cfg.preloadModels != []) {
      description = "Preload Ollama models (idempotent)";
      wantedBy = ["multi-user.target"];
      after = ["ollama.service"];
      requires = ["ollama.service"];

      serviceConfig = {
        Type = "oneshot";
        User = "ollama";
        Group = "ollama";
        # WorkingDirectory = cfg.ollamaDataDir;

        # Fix the panic:
        Environment = [
          "PATH=${lib.makeBinPath [pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.curl pkgs.jq config.services.ollama.package]}"
          "HOME=${cfg.ollamaDataDir}" # avoids the $HOME panic
          "OLLAMA_HOST=127.0.0.1:${toString cfg.ollamaPort}"
          "OLLAMA_MODELS=${cfg.ollamaDataDir}/models"
        ];
      };

      script = let
        ollama = "${config.services.ollama.package}/bin/ollama";
        models = lib.concatStringsSep " " cfg.preloadModels;
      in ''
        set -euo pipefail

        echo "Checking existing Ollama models..."
        existing="$(${ollama} list | awk 'NR>1 {print $1}')"

        for model in ${models}; do
          if echo "$existing" | grep -qx "$model"; then
            echo "✔ Model already present: $model"
          else
            echo "⬇ Pulling missing model: $model"
            ${ollama} pull "$model"
          fi
        done
      '';
    };
  };
}
