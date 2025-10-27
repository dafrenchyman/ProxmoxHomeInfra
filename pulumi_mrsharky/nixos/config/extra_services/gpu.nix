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
  config = lib.mkIf cfg.enable {
    boot.initrd.kernelModules = ["amdgpu"];
    #boot.kernelModules = [ "amdgpu" ];
    boot.initrd.availableKernelModules = ["amdgpu"];

    # Doesn't work
    #boot.initrd.includeFirmware = true;

    nixpkgs.config.allowUnfree = true;
    hardware.enableAllFirmware = true;
    # boot.initrd.includeFirmware = true;

    # Need to use a newer kernel to have access to the iGPU drivers
    boot.kernelPackages = pkgs.linuxPackages;
    # hardware.firmware = [
    #   (import <nixpkgs> { system = "x86_64-linux"; }).unstable.linux-firmware
    # ];

    # Force loading amdgpu early and allow experimental features
    boot.kernelParams = [
      "amdgpu.ppfeaturemask=0xffffffff"
      # "nomodeset"  # Optional: if troubleshooting framebuffer issues
      "amdgpu.gfxoff=0"
      "amdgpu.tmz=0"
    ];

    # Include all firmware (required for iGPU PSP, VCN, etc.)
    hardware.firmware = with pkgs; [
      linux-firmware
      firmwareLinuxNonfree
    ];

    hardware.opengl = {
      enable = true;
      #driSupport = true;
      driSupport32Bit = true;
      extraPackages = with pkgs; [vaapiVdpau libvdpau-va-gl];
    };

    # hardware.firmware = [
    #   pkgs.linux-firmware
    #   (pkgs.runCommand "custom-amdgpu-firmware" {
    #     nativeBuildInputs = [ pkgs.zstd ];
    #   } ''
    #     mkdir -p $out/lib/firmware/amdgpu
    #     zstd -d ${pkgs.linux-firmware}/lib/firmware/amdgpu/psp_13_0_4_toc.bin.zst -o $out/lib/firmware/amdgpu/psp_13_0_4_toc.bin
    #     zstd -d ${pkgs.linux-firmware}/lib/firmware/amdgpu/psp_13_0_4_ta.bin.zst -o $out/lib/firmware/amdgpu/psp_13_0_4_ta.bin
    #   '')
    # ];

    environment.systemPackages = with pkgs; [
      ffmpeg-full
      glxinfo
      libva
      libva-utils
      libvdpau-va-gl
      mesa
      mesa.drivers
      radeontop
      vaapiVdpau
      vulkan-tools
    ];
  };
}
