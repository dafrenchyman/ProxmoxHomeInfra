{
  pkgs,
  lib,
  config,
  ...
}: {
  options.applications.pycharm = {
    enable = lib.mkEnableOption "PyCharm Professional IDE";
    version = lib.mkOption {
      type = lib.types.str;
      default = "2025.3.2.1";
      description = "PyCharm Professional version to install";
    };
  };

  config = let
    # Nix darwin DMG installation
    cfg = config.applications.pycharm;
    pycharmProfessional = pkgs.stdenv.mkDerivation {
      name = "pycharm-professional-${cfg.version}";
      src = pkgs.fetchurl {
        url = "https://download.jetbrains.com/python/pycharm-professional-${cfg.version}-aarch64.dmg";
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
  in
    lib.mkIf cfg.enable {
      environment.systemPackages = [pycharmProfessional];
    };
}
