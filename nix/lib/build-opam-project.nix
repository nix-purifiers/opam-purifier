# SPDX-License-Identifier: MIT
#
# buildOpamProject: the sandboxed build of an opam project, from the
# lockfile `opam-purifier lock` writes at the project root.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# opam-purifier overlay (`overlays.default`) adds it to the package set as
# `buildOpamProject`, so a package written for callPackage takes it like
# any other dependency:
#
#   { buildOpamProject }: (buildOpamProject { src = ./.; }).packages.hello
#
# and `buildOpamProject.override` replaces what it takes from the set.
# The builder returns
#
#   switch            an opam switch at `switch/_opam` with the locked
#                     dependencies and the project's packages installed
#   packages.<name>   the files the project's package <name> installs, as
#                     the lock run recorded them; `files.<path>` names
#                     each, and `executables.<name>` each one under bin/
#   releases.<name>   the source archive to publish package <name> with,
#                     at <name>-<version>.tar.gz
#   state             the offline state the build installs from
{
  lib,
  stdenv,
  callPackage,
  runCommand,
  opam,
  rsync,
  unzip,
  which,
  pkg-config,
  pkgs,
}:
{
  # The root of the opam project, where its opam files are.
  src,
  # The lockfile; the default is the one `opam-purifier lock` writes at
  # the project root.
  lockFile ? src + "/opam-purifier.lock.json",
  # The name of `switch`.
  name ? "opam-project",
  # Replaces the built-in fetcher for files; see fetch.nix.
  fetchurl ? null,
  # Replaces nixpkgs' fetchgit, for credentials to private repositories.
  fetchgit ? pkgs.fetchgit,
  # More build tools and libraries, beside the ones the locked packages
  # name as depexts for NixOS.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # Builds and runs the project's tests (`opam install --with-test`). The
  # default is true when the lock holds the test dependencies, which it
  # does unless it was made with --without-test.
  doCheck ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out version control,
  # opam's local switch, the purifier's state, build outputs and the
  # lockfile, which Nix reads at evaluation and the build never reads.
  # Leaving the lockfile out keeps the switch the lock run built when the
  # lock run then adds the outputs to the lockfile.
  srcFilter ? null,
}:
let
  lock =
    let
      read = import ./lock.nix { inherit lockFile; };
    in
    assert
      read.isCurrentFor src
      || throw "opam-purifier: ${toString lockFile} was made from other opam files than the ones in ${toString src}; run `opam-purifier lock`.";
    read;
  system = stdenv.hostPlatform.system;
  state = callPackage ./state.nix {
    inherit
      lockFile
      system
      fetchurl
      fetchgit
      ;
  };
  solution = state.solution;

  defaultSrcFilter =
    path: type:
    let
      base = baseNameOf path;
    in
    !(
      base == ".git"
      || base == "_opam"
      || base == "_build"
      || base == ".opam-purifier"
      || base == "opam-purifier.lock.json"
      || lib.hasPrefix "result" base
    );

  filteredSrc = builtins.path {
    path = src;
    name = "opam-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  platformEnv = {
    OPAMVAR_arch =
      {
        "x86_64-linux" = "x86_64";
        "aarch64-linux" = "arm64";
      }
      .${system};
    OPAMVAR_os = "linux";
    OPAMVAR_os_family = "nixos";
    OPAMVAR_os_distribution = "nixos";
  };

  doCheck' = if doCheck != null then doCheck else lock.options.withTest;

  switch = stdenv.mkDerivation (
    platformEnv
    // {
      inherit name;
      doCheck = doCheck';
      src = filteredSrc;
      nativeBuildInputs = [
        opam
        rsync
        unzip
        which
        pkg-config
      ]
      ++ nativeBuildInputs;
      buildInputs = import ./depexts.nix { inherit lib pkgs; } solution ++ buildInputs;
      dontConfigure = true;
      # opam runs the tests during its install when doCheck is set.
      dontCheck = true;
      buildPhase = ''
        runHook preBuild
        export HOME="$TMPDIR/home"
        export OPAMROOT="$TMPDIR/opam-root"
        export OPAMYES=1 OPAMNODEPEXTS=1 OPAMCOLOR=never OPAMSTATUSLINE=never
        export OPAMNOENVNOTICE=1 OPAMCONFIRMLEVEL=unsafe-yes
        export OPAMFETCH="${state}/bin/offline-fetch %{url}% %{out}%"
        export OPAMJOBS="$NIX_BUILD_CORES"
        mkdir -p "$HOME" "$out"
        project="$PWD"
        bash ${state}/bin/install-dependencies "$out" "$project"
        export OPAMSWITCH="$out"
        opam install --ignore-pin-depends ${lib.optionalString doCheck' "--with-test"} ${
          lib.escapeShellArgs (map (p: "./" + p.opamFile) lock.packages)
        }
        # The files each of the project's packages installed, which the
        # lock run records as the outputs.
        mkdir -p "$out/nix-support/opam-purifier-files"
        ${lib.concatMapStrings (p: ''
          opam show --list-files ${lib.escapeShellArg p.name} > "$out/nix-support/opam-purifier-files/"${lib.escapeShellArg p.name}
        '') lock.packages}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        # The switch keeps what it installed; the copies of the sources it
        # built from go.
        rm -rf "$out/_opam/.opam-switch/sources" "$out/_opam/.opam-switch/build" "$out/_opam/.opam-switch/backup"
        runHook postInstall
      '';
      passthru = {
        inherit state lock;
      };
    }
  );

  mkPackage =
    package:
    let
      drv =
        runCommand "${package.name}-${package.version}"
          {
            files = lib.concatMapStrings (f: "${f}\n") package.files;
            passAsFile = [ "files" ];
            passthru = {
              inherit (package) version;
              files = lib.genAttrs package.files (f: "${drv}/${f}");
              executables = lib.listToAttrs (
                map (f: lib.nameValuePair (lib.removePrefix "bin/" f) "${drv}/${f}") (
                  lib.filter (f: lib.hasPrefix "bin/" f) package.files
                )
              );
            };
          }
          ''
            mkdir -p $out
            while IFS= read -r rel; do
              if [ ! -e "${switch}/_opam/$rel" ]; then
                echo "opam-purifier: ${package.name} did not install $rel, which the lock recorded; run \`opam-purifier relock\`" >&2
                exit 1
              fi
              mkdir -p "$(dirname "$out/$rel")"
              cp -a "${switch}/_opam/$rel" "$out/$rel"
            done < "$filesPath"
          '';
    in
    drv;

  releases = lib.listToAttrs (
    map (
      package:
      lib.nameValuePair package.name (
        callPackage ./release-archive.nix {
          src = import ./release-source.nix { inherit lib src; };
          inherit (package) name version;
        }
      )
    ) lock.packages
  );
in
{
  inherit switch state releases;
  packages = lib.listToAttrs (map (p: lib.nameValuePair p.name (mkPackage p)) lock.packages);
}
