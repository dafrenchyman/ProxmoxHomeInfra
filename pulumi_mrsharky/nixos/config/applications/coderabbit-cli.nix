{
  pkgs,
  lib,
  config,
  ...
}: {
  options.applications.coderabbitCli = {
    enable = lib.mkEnableOption "CodeRabbit CLI";

    version = lib.mkOption {
      type = lib.types.str;
      # Latest version can be found here: https://cli.coderabbit.ai/releases/latest/VERSION
      default = "0.3.6";
      description = "CodeRabbit CLI version tag, e.g. 0.3.6";
    };

    sha256 = lib.mkOption {
      type = lib.types.str;
      default = "s5A/FDmEQ28kGyQniV5entMAdjeLIR+/oC/DiJocw6k="; # pragma: allowlist secret
      description = "sha256 for the coderabbit zip artifact for your platform";
    };

    # If you're on Apple Silicon, this should be arm64.
    # On Intel macs, use x64.
    arch = lib.mkOption {
      type = lib.types.enum ["arm64" "x64"];
      default =
        if pkgs.stdenv.hostPlatform.isAarch64
        then "arm64"
        else "x64";
      description = "Architecture for the downloaded artifact (arm64 or x64).";
    };

    installAlias = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also install `cr` as an alias to `coderabbit`.";
    };
  };

  config = let
    cfg = config.applications.coderabbitCli;

    coderabbitCli = pkgs.stdenvNoCC.mkDerivation {
      name = "coderabbit-cli-${cfg.version}";

      src = pkgs.fetchurl {
        url = "https://cli.coderabbit.ai/releases/${cfg.version}/coderabbit-darwin-${cfg.arch}.zip";
        sha256 = cfg.sha256;
      };

      nativeBuildInputs = [pkgs.unzip];

      phases = ["unpackPhase" "installPhase"];

      unpackPhase = ''
        mkdir -p unpack
        unzip -q "$src" -d unpack
      '';

      installPhase = ''
        set -euo pipefail
        mkdir -p "$out/bin"

        if [ ! -f unpack/coderabbit ]; then
          echo "Expected unpack/coderabbit not found in zip."
          echo "Contents:"
          find unpack -maxdepth 2 -type f -print
          exit 1
        fi

        install -m 0755 unpack/coderabbit "$out/bin/coderabbit"

        ${lib.optionalString cfg.installAlias ''
          ln -s "$out/bin/coderabbit" "$out/bin/cr"
        ''}
      '';

      meta = with lib; {
        description = "CodeRabbit CLI (pinned zip install)";
        platforms = platforms.unix;
        mainProgram = "coderabbit";
      };
    };
  in
    lib.mkIf cfg.enable {
      # Ensure git is present since their script claims it's required for functionality
      environment.systemPackages = [coderabbitCli pkgs.git];
    };
}
