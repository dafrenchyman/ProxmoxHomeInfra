{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.applications.ekpar2;

  version = "0.7.1";

  ekpar2Pkg = pkgs.stdenv.mkDerivation {
    pname = "ekpar2";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://mrsharky.com/extras/ekpar2-${version}.tar.gz";

      # When updating to a new version (probably won't happen, this program is crazy old)
      # You'll want to update the SHA to the newer one
      sha256 = "sha256-vqNMcHcLsIsmOOWyKS/2ATuX02wn7nvBEK3ZqOtcvWo="; # pragma: allowlist secret
    };

    nativeBuildInputs = [
      pkgs.cmake
      pkgs.extra-cmake-modules
      pkgs.pkg-config

      # Wraps Qt/KDE apps so they find plugins, QML, icons, etc.
      pkgs.libsForQt5.wrapQtAppsHook
    ];

    buildInputs = [
      pkgs.libsForQt5.qtbase
      pkgs.libsForQt5.kwidgetsaddons
      pkgs.libsForQt5.kxmlgui
      pkgs.libsForQt5.kio
    ];

    cmakeFlags = [
      "-DCMAKE_BUILD_TYPE=Release"
    ];

    # Optional: let you append custom install tweaks if needed later
    postInstall = cfg.postInstall;

    meta = with lib; {
      description = "EKPar2 (KDE/Qt PAR2 utility)";
      homepage = "https://sourceforge.net/projects/ekpar2/";
      platforms = platforms.linux;
      mainProgram = "ekpar2";
      license = licenses.gpl3Only;
    };
  };
in {
  options.applications.ekpar2 = {
    enable = lib.mkEnableOption "EKPar2 (build from source)";

    package = lib.mkOption {
      type = lib.types.package;
      default = ekpar2Pkg;
      description = "The ekpar2 package to install (override to use a different derivation).";
    };

    postInstall = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Optional shell snippet appended to the package postInstall phase.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.par2cmdline
      cfg.package
    ];
  };
}
