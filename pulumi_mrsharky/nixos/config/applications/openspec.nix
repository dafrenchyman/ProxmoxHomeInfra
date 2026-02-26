{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.applications.openspec;

  # NPM package name
  npmName = "@fission-ai/openspec";
  version = "1.2.0";

  pnameSafe = "openspec";

  # Get the lockfile from github (it's not part of the tarball)
  lockfile = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/Fission-AI/OpenSpec/refs/tags/v1.2.0/package-lock.json";
    sha256 = "sha256-H8Fc8HLWnkuWWO92Mta2MQcXr0IWft5UsIis91y8Sno="; # pragma: allowlist secret
  };

  openspecPkg = pkgs.buildNpmPackage {
    pname = pnameSafe;
    inherit version;

    # Pull the tarball for the chosen version from npm
    src = pkgs.fetchurl {
      #  npm tarballs live under: https://registry.npmjs.org/@scope/name/-/name-VERSION.tgz
      url = "https://registry.npmjs.org/${npmName}/-/${pnameSafe}-${version}.tgz";
      sha256 = "sha256-Ks7alGk/HbCw0uo8dQoqQYc36rMNAm0dBmYplFzemLo="; # pragma: allowlist secret
    };

    # buildNpmPackage expects the lockfile at the source root.
    # NPM tarballs unpack to "package/", and buildNpmPackage sets sourceRoot="package",
    postPatch = ''
      if [ ! -f ${lockfile} ]; then
        echo "ERROR: lockfile not found at ${lockfile}"
        exit 1
      fi
      cp ${lockfile} package-lock.json
    '';

    # Dependency hash
    npmDepsHash = "sha256-O93JSRretbgMeckwCGysxyle+eXRutg2OXooCAo8iyc="; # pragma: allowlist secret

    # CLIs don't need a build step beyond installing deps
    # If it *does* need a build, set this to false.
    dontNpmBuild = true;

    # Some CLIs expect node-gyp / native deps; add here only if needed
    nativeBuildInputs = lib.optionals cfg.withPython [pkgs.python3];

    # Optional: if the package doesn't expose the right bin automatically,
    # you can add extra wrapping/symlinks in postInstall.
    postInstall = cfg.postInstall;

    meta = with lib; {
      description = "OpenSpec CLI (${npmName})";
      platforms = platforms.unix;
      mainProgram = "openspec";
    };
  };
in {
  options.applications.openspec = {
    enable = lib.mkEnableOption "OpenSpec CLI";

    withPython = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable if the package uses node-gyp and needs python during build.";
    };

    postInstall = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Optional shell snippet appended to postInstall.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      openspecPkg
    ];
  };
}
