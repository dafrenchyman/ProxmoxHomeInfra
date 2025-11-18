{
  config,
  lib,
  pkgs,
  ...
}:
#############################
# Enable GPU
#############################
let
  # An object containing user configuration (in /etc/nixos/configuration.nix)
  cfg = config.extraServices.gpu;
in {
  options.extraServices.gpu = {
    # Create the main option to toggle the service state
    enable = lib.mkEnableOption "gpu";

    gpu_type = lib.mkOption {
      type = lib.types.enum ["software" "amd" "nvidia"];
      default = "software";
      description = "Select which GPU type to configure.";
    };
  };

  # Everything that should be done when/if the service is enabled
  config = lib.mkIf cfg.enable (lib.mkMerge [
    ####################################
    # Common settings (any GPU type)
    ####################################
    {
      nixpkgs.config.allowUnfree = true;
      hardware.enableAllFirmware = true;

      # Use a recent kernel (you can override if you want a specific one)
      boot.kernelPackages = pkgs.linuxPackages;

      # Basic graphics stack (works for AMD/NVIDIA; harmless for software)
      hardware.opengl = {
        enable = true;
        #driSupport = true;
        driSupport32Bit = true;
        extraPackages = with pkgs; [
          vaapiVdpau
          libvdpau-va-gl
        ];
      };

      environment.systemPackages = with pkgs; [
        ffmpeg-full
        glxinfo
        libva
        libva-utils
        libvdpau-va-gl
        mesa
        mesa.drivers
        vaapiVdpau
        vulkan-tools
      ];
    }

    ####################################
    # AMD GPU
    ####################################
    (lib.mkIf (cfg.gpu_type == "amd") {
      boot.initrd.kernelModules = ["amdgpu"];
      boot.initrd.availableKernelModules = ["amdgpu"];

      # Force loading amdgpu early and allow experimental features
      boot.kernelParams = [
        "amdgpu.ppfeaturemask=0xffffffff"
        "amdgpu.gfxoff=0"
        "amdgpu.tmz=0"
      ];

      # Include all firmware (required for iGPU PSP, VCN, etc.)
      hardware.firmware = with pkgs; [
        linux-firmware
        firmwareLinuxNonfree
      ];

      environment.systemPackages = with pkgs; [
        radeontop
      ];
    })

    ####################################
    # NVIDIA GPU
    ####################################
    (lib.mkIf (cfg.gpu_type == "nvidia") {
      # Use the proprietary NVIDIA driver
      services.xserver.videoDrivers = ["nvidia"];

      # Disable nouveau to avoid conflicts
      boot.blacklistedKernelModules = ["nouveau"];

      hardware.nvidia = {
        modesetting.enable = true;
        powerManagement.enable = true;
        powerManagement.finegrained = false;

        # Set to true if you have a GPU that supports the open kernel driver,
        # otherwise leave as false.
        open = false;

        # Adds the nvidia-settings GUI tool (harmless on a server)
        nvidiaSettings = true;

        # Optional: explicitly pick a package version
        # package = config.boot.kernelPackages.nvidiaPackages.stable;
      };

      #      environment.systemPackages = with pkgs; [
      #        nvidia-smi
      #      ];
    })

    ####################################
    # Software-only (no GPU)
    ####################################
    (lib.mkIf (cfg.gpu_type == "software") {
      # Nothing special; you could explicitly avoid any GPU-specific config here
      # or add software-rendering-only tools if you want.
    })
  ]);
}
