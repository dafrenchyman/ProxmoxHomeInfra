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
      package = pkgs.ollama-cuda;
      loadModels = [
        "llama3.1:8b"
        "qwen2.5-coder:7b"
      ];

      # Bind to the chosen interface/port
      host = cfg.ollamaHost;
      port = cfg.ollamaPort;

      # Persist models
      #dataDir = cfg.ollamaDataDir;

      # GPU note:
      # On many nixpkgs versions, with NVIDIA drivers installed, Ollama will use CUDA.
      # Some nixpkgs versions include an explicit option like:
      #   acceleration = "cuda";
      # If your build errors here, remove/adjust accordingly.
      #
      # acceleration = "cuda";
    };

    systemd.services.ollama.environment = {
      LD_LIBRARY_PATH = "/run/opengl-driver/lib:/run/opengl-driver-32/lib";
    };
    # GPU
    services.xserver.videoDrivers = ["nvidia"];
    hardware.nvidia.modesetting.enable = true;
    hardware.opengl.enable = true; # (or hardware.graphics.enable on newer nixpkgs)

    #    environment.systemPackages = [
    #     (pkgs.ollama.override {
    #        acceleration = "cuda";
    #      })
    #    ];

    # Ensure NVIDIA stack is enabled (you likely already have this).
    # Keep this block if this machine is the 3090 server.
    # hardware.graphics.enable = lib.mkDefault true;
    # services.xserver.videoDrivers = lib.mkDefault [ "nvidia" ];

    # For container runtime convenience (Open WebUI container)
    #virtualisation.podman = {
    # enable = true;
    # dockerCompat = true;
    # defaultNetwork.settings.dns_enabled = true;
    #};

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
      description = "Preload Ollama models (best-effort)";
      wantedBy = ["multi-user.target"];
      after = ["ollama.service"];
      requires = ["ollama.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        pulls = lib.concatStringsSep "\n" (map (m: ''
            echo "Pulling model: ${m}"
            ${pkgs.ollama}/bin/ollama pull ${lib.escapeShellArg m} || true
          '')
          cfg.preloadModels);
      in ''
        set -euo pipefail
        ${pulls}
      '';
    };
  };
}
