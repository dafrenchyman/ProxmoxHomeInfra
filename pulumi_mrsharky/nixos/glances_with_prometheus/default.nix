# Below, we can supply defaults for the function arguments to make the script
# runnable with `nix-build` without having to supply arguments manually.
# Also, this lets me build with Python 3.7 by default, but makes it easy
# to change the python version for customised builds (e.g. testing).
{ nixpkgs ? import <nixpkgs> {}, pythonPkgs ? nixpkgs.pkgs.python311Packages }:

let
  # This takes all Nix packages into this scope
  inherit (nixpkgs) pkgs;
  # This takes all Python packages from the selected version into this scope.
  inherit pythonPkgs;

  # Inject dependencies into the build function
  f = {
    bottle
    , defusedxml
    , future
    , ujson
    , netifaces
    , packaging
    , psutil
    , pysnmp
    , prometheus_client
    , setuptools
    , py-cpuinfo
    , stdenv
    , fetchFromGitHub
    , python3Packages
    , fetchpatch
    , lib
    , hddtemp
    , isPyPy ? false  # Define isPyPy with a default value of false
  }:
    python3Packages.buildPythonApplication rec {
      pname = "glances_with_prometheus";
      version = "3.4.0.3";
      disabled = isPyPy;

      src = fetchFromGitHub {
        owner = "nicolargo";
        repo = "glances";
        rev = "refs/tags/v${version}";
        hash = "sha256-TakQqyHKuiFdBL73JQzflNUMYmBINyY0flqitqoIpmg=";  # pragma: allowlist secret
      };

      # On Darwin this package segfaults due to mismatch of pure and impure
      # CoreFoundation. This issues was solved for binaries but for interpreted
      # scripts a workaround below is still required.
      # Relevant: https://github.com/NixOS/nixpkgs/issues/24693
      makeWrapperArgs = lib.optionals stdenv.isDarwin [
        "--set" "DYLD_FRAMEWORK_PATH" "/System/Library/Frameworks"
      ];

      doCheck = true;
      preCheck = lib.optionalString stdenv.isDarwin ''
        export DYLD_FRAMEWORK_PATH=/System/Library/Frameworks
      '';

      postInstall = ''
        mkdir -p $out/etc/glances
        cp $src/conf/glances.conf $out/etc/glances/glances.conf
        chmod 644 $out/etc/glances/glances.conf
      '';

      propagatedBuildInputs = [
        bottle
        defusedxml
        future
        ujson
        netifaces
        packaging
        psutil
        pysnmp
        prometheus_client
        setuptools
        py-cpuinfo
      ] ++ lib.optional stdenv.isLinux hddtemp;

      meta = with lib; {
        homepage = "https://nicolargo.github.io/glances/";
        description = "Cross-platform curses-based monitoring tool";
        changelog = "https://github.com/nicolargo/glances/blob/v${version}/NEWS.rst";
        license = licenses.lgpl3Only;
        maintainers = with maintainers; [ jonringer primeos koral ];
      };
    };

  drv = pythonPkgs.callPackage f {};
in
  if pkgs.lib.inNixShell then drv.env else drv

