{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.applications.codex;

  version = "0.114.0";

  systemToAsset = {
    x86_64-linux = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-musl.tar.gz";
      sha256 = "sha256-kinejFHI7zBWW7UHyXou3ASoCzjkmkNj8zf+Bb7fNOs="; # pragma: allowlist secret
      binaryName = "codex-x86_64-unknown-linux-musl";
    };
    aarch64-linux = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-unknown-linux-musl.tar.gz";
      sha256 = "sha256-H8Fc8HLWnkuWWO92Mta2MQcXr0IWft5UsIis91y8Sno="; # pragma: allowlist secret
      binaryName = "codex-aarch64-unknown-linux-musl";
    };
  };

  asset =
    systemToAsset.${pkgs.stdenv.hostPlatform.system}
    or (throw "Unsupported system for codex: ${pkgs.stdenv.hostPlatform.system}");

  codexPkg = pkgs.stdenv.mkDerivation {
    pname = "codex";
    inherit version;

    src = pkgs.fetchurl {
      inherit (asset) url sha256;
    };

    sourceRoot = ".";

    nativeBuildInputs = [pkgs.autoPatchelfHook];
    buildInputs = [pkgs.stdenv.cc.cc.lib];

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      tar -xzf $src
      install -m755 ${asset.binaryName} $out/bin/codex

      runHook postInstall
    '';

    meta = with lib; {
      description = "Codex CLI";
      homepage = "https://github.com/openai/codex";
      license = licenses.asl20;
      platforms = builtins.attrNames systemToAsset;
      mainProgram = "codex";
    };
  };
in {
  options.applications.codex = {
    enable = lib.mkEnableOption "Codex CLI";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [codexPkg];
  };
}
