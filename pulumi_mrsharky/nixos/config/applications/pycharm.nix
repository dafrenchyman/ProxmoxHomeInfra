{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.applications.pycharm;
  stdenv = pkgs.stdenv;

  linuxVersion = "2025.3.3";
  darwinVersion = "2025.3.2.1";

  linuxSrc =
    if stdenv.hostPlatform.system == "x86_64-linux"
    then
      pkgs.fetchurl {
        url = "https://download.jetbrains.com/python/pycharm-2025.3.3.tar.gz";
        sha256 = "02jaibdrqgvlfcz3r5qx1sn0dcrcdmaqlidhbsgvfgmq1q254xrl";
      }
    else if stdenv.hostPlatform.system == "aarch64-linux"
    then
      pkgs.fetchurl {
        url = "https://download.jetbrains.com/python/pycharm-2025.3.3-aarch64.tar.gz";
        sha256 = "033aga5axhfhypb8b2vwvxy988b47rxjx9i21lwrl2hgh3lj9kh8";
      }
    else throw "Unsupported Linux platform for applications.pycharm: ${stdenv.hostPlatform.system}";

  pycharmProfessionalDarwin = pkgs.stdenv.mkDerivation {
    name = "pycharm-professional-${darwinVersion}";
    src = pkgs.fetchurl {
      url = "https://download.jetbrains.com/python/pycharm-professional-${darwinVersion}-aarch64.dmg";
      sha256 = "031b35fd0d2d67ee1989d512c3c2cc1952ce1269a29e7f9e790c7d4a0d6f2eb2"; # pragma: allowlist secret
    };

    buildInputs = [pkgs.undmg];
    phases = ["unpackPhase" "installPhase"];

    unpackPhase = ''
      undmg $src
    '';

    installPhase = ''
      mkdir -p $out/Applications
      cp -r PyCharm.app $out/Applications/PyCharmProfessional.app
    '';
  };

  # Reuse nixpkgs' JetBrains Linux packaging so the IDE gets the normal wrapper,
  # icon handling, and .desktop launcher integration for X11/desktop menus.
  pycharmProfessionalLinux = pkgs.jetbrains."pycharm-professional".overrideAttrs (oldAttrs: {
    version = linuxVersion;
    src = linuxSrc;
    passthru =
      (oldAttrs.passthru or {})
      // {
        buildNumber = linuxVersion;
      };
  });

  pycharmProfessional =
    if stdenv.isDarwin
    then pycharmProfessionalDarwin
    else if stdenv.isLinux
    then pycharmProfessionalLinux
    else throw "Unsupported platform for applications.pycharm: ${stdenv.hostPlatform.system}";
in {
  options.applications.pycharm = {
    enable = lib.mkEnableOption "PyCharm Professional IDE";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [pycharmProfessional];
  };
}
