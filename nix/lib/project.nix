# SPDX-License-Identifier: MIT
#
# Everything the library builds for an opam project, from the lockfile
# `opam-purifier lock` writes. build-opam-project.nix returns the part of
# it that the purifier contract names. The commands build the rest:
#
#   switch    an opam switch at `switch/_opam` with the locked
#             dependencies and the project's packages installed; the lock
#             run reads the outputs from nix-support/opam-purifier-files
#   tests     the same switch, built with `--with-test`, so that opam runs
#             the tests of the project's packages
#   packages  the files each package installs, as the lockfile records
#             them
#   release   the source archive that `opam-purifier publish` submits
#   fetches   the download entries of the lockfile
#   state     the offline state the switch installs from (state.nix)
#   shell     the environment of the everyday loop: the tools of the
#             sandboxed build and the system packages the depexts name
{ purifier }:
{
  pkgs,
  # The root of the opam project, where its opam files are.
  src,
  # The lockfile. It can live outside `src`, and the build then ignores
  # any copy of it in `src`.
  lockFile ? src + "/opam-purifier.lock.json",
  # Passed to fetchEntry and tree of the purifier library, such as a
  # `fetchurl` that sends credentials or tries a company mirror.
  fetchers ? { },
  # The name of the switch.
  name ? "opam-project",
  # The package whose name and version name the release archive. The
  # default is the first of the project's packages by name.
  releasePackage ? null,
  # More build tools and libraries, beside the ones the locked packages
  # name as depexts for NixOS.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out version control,
  # opam's local switch, the purifier's state, build outputs and the
  # lockfile. Nix reads the lockfile at evaluation, and the build reads
  # none of it, so the lock run can add the outputs to the lockfile
  # without changing the switch it built.
  srcFilter ? null,
}:
let
  inherit (pkgs) lib stdenv;
  system = stdenv.hostPlatform.system;

  lock = import ./lock.nix { inherit lockFile src; };
  solution = lock.forSystem system;

  state = import ./state.nix {
    inherit
      pkgs
      purifier
      lock
      system
      fetchers
      ;
  };

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

  tools = [
    pkgs.opam
    pkgs.rsync
    pkgs.unzip
    pkgs.which
    pkgs.pkg-config
  ];
  depexts = import ./depexts.nix { inherit lib pkgs; } solution;

  localNames = map (p: p.name) lock.packages;

  mkSwitch =
    { withTest }:
    stdenv.mkDerivation (
      platformEnv
      // {
        name = if withTest then "${name}-tests" else name;
        src = filteredSrc;
        nativeBuildInputs = tools ++ nativeBuildInputs;
        buildInputs = depexts ++ buildInputs;
        dontConfigure = true;
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
          opam install --ignore-pin-depends ${lib.escapeShellArgs (map (p: "./" + p.opamFile) lock.packages)}
          ${lib.optionalString withTest ''
            # The tests run once every package of the project is installed.
            # A test of one package often uses another package of the same
            # project without declaring it, which a dune build at the
            # project root never notices.
            opam reinstall --ignore-pin-depends --with-test ${lib.escapeShellArgs localNames}
          ''}
          # The files each of the project's packages installed, which the
          # lock run records as the outputs.
          mkdir -p "$out/nix-support/opam-purifier-files"
          ${lib.concatMapStrings (n: ''
            opam show --list-files ${lib.escapeShellArg n} > "$out/nix-support/opam-purifier-files/"${lib.escapeShellArg n}
          '') localNames}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          # The switch keeps what it installed. The copies of the sources it
          # built from, the backups and the logs of the build go.
          rm -rf "$out/_opam/.opam-switch/sources" "$out/_opam/.opam-switch/build" \
            "$out/_opam/.opam-switch/backup" "$out/_opam/.opam-switch/packages/cache"
          runHook postInstall
        '';
        passthru = {
          inherit state lock;
        };
      }
    );

  switch = mkSwitch { withTest = false; };

  tests =
    if lock.options.withTest then
      mkSwitch { withTest = true; }
    else
      throw "opam-purifier: ${toString lockFile} was locked with --without-test, so it holds no test dependencies; run `opam-purifier lock` without it.";

  mkPackage =
    package:
    let
      drv =
        pkgs.runCommand "${package.name}-${package.version}"
          {
            files = lib.concatMapStrings (f: "${f}\n") package.files;
            passAsFile = [ "files" ];
            passthru = {
              inherit (package) version;
              inherit switch;
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
                echo "opam-purifier: ${package.name} did not install $rel, which the lock recorded; run \`opam-purifier lock\`" >&2
                exit 1
              fi
              mkdir -p "$(dirname "$out/$rel")"
              cp -a "${switch}/_opam/$rel" "$out/$rel"
            done < "$filesPath"
          '';
    in
    drv;

  releaseName =
    if releasePackage != null then releasePackage else lib.head (lib.sort lib.lessThan localNames);
  releaseEntry =
    lib.findFirst (p: p.name == releaseName)
      (throw "opam-purifier: ${releaseName} is not a package of this project; its packages are ${lib.concatStringsSep ", " localNames}.")
      lock.packages;

  release = import ./release-archive.nix {
    inherit pkgs;
    src = import ./release-source.nix { inherit lib src; };
    inherit (releaseEntry) name version;
  };

  shell = pkgs.mkShell (
    platformEnv // { packages = tools ++ depexts ++ nativeBuildInputs ++ buildInputs; }
  );
in
{
  inherit
    switch
    tests
    release
    state
    shell
    lock
    ;
  packages = lib.listToAttrs (map (p: lib.nameValuePair p.name (mkPackage p)) lock.packages);
  fetches = lock.downloads;
}
