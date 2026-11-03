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
#   shell     the environment of the development loop: the tools of the
#             sandboxed build and the system packages the depexts name
{ purifier }:
{
  pkgs,
  # The root of the opam project, where its opam files are.
  src,
  # The lockfile. It can live outside `src`, and the build then ignores
  # any copy of it in `src`.
  lockFile ? src + "/opam-purifier.lock.json",
  # A directory that holds opam's lock files (<package>.opam.locked), which
  # the build uses in place of the ones in `src`. An external build keeps
  # them beside its own flake. The default is the ones in `src`.
  opamLocked ? null,
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
  # opam's local switch, the purifier's state, build outputs, the lockfile
  # and opam's own lock files. Nix reads those at evaluation, and the
  # build reads none of them, so the lock run can add the outputs to the
  # lockfile, and `update` can write opam's lock files, without changing
  # the switch they were built from.
  srcFilter ? null,
}:
let
  inherit (pkgs) lib stdenv;
  system = stdenv.hostPlatform.system;

  # The lock in memory, checked by the purifier library, which fails
  # evaluation with the problems, each naming the command to run.
  checked = purifier.checkLock (
    import ./read-lock.nix { inherit lib; } { inherit src lockFile opamLocked; }
  );
  lock = builtins.seq checked (import ./lock.nix { inherit lockFile src opamLocked; }).lock;
  solution = lock.forSystem system;
  derived = import ./derive.nix { inherit lib lock; };

  state = import ./state.nix {
    inherit
      pkgs
      purifier
      lock
      derived
      system
      fetchers
      ;
    entries = purifier.entriesFor system checked;
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
      || lib.hasSuffix ".opam.locked" base
      || lib.hasPrefix "result" base
    );

  filteredSrc = builtins.path {
    path = src;
    name = "opam-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  # The values the lock run sets (platform_env in bin/opam-purifier). On
  # macOS the family and distribution stay NixOS, whose depexts name
  # nixpkgs attributes.
  platformEnv = {
    OPAMVAR_arch =
      {
        "x86_64-linux" = "x86_64";
        "aarch64-linux" = "arm64";
        "aarch64-darwin" = "arm64";
      }
      .${system};
    OPAMVAR_os = if stdenv.hostPlatform.isDarwin then "macos" else "linux";
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
          # opam's own lock files of the project's packages, at the versions
          # this switch installed, which `opam-purifier update` writes into
          # a project that keeps them.
          mkdir -p "$out/nix-support/opam-locked"
          (cd "$out/nix-support/opam-locked" && opam lock ${lib.escapeShellArgs localNames} > /dev/null)
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          # The switch keeps what it installed. The copies of the sources it
          # built from, the backups and the logs of the build go.
          rm -rf "$out/_opam/.opam-switch/sources" "$out/_opam/.opam-switch/build" \
            "$out/_opam/.opam-switch/backup" "$out/_opam/.opam-switch/packages/cache"
          # opam records the modification time of every file it installs in
          # <package>.changes. Nix sets the time of each file in the store to
          # 1, so the recorded time becomes that, and two builds agree.
          # opam also wraps a long entry onto a second line, depending on
          # the length of the time it printed, so wrapped entries are joined.
          find "$out/_opam/.opam-switch/install" -name '*.changes' \
            -exec sed -z -i -E 's/(F:S[0-9]+T)[0-9.]+/\11/g; s/"\n +\{/" {/g' {} +
          runHook postInstall
        '';
        passthru = {
          inherit state lock;
        };
      }
      // lib.optionalAttrs stdenv.hostPlatform.isDarwin {
        # opam records the build directory (the opam root, and the source of
        # the project's packages, which it pins) and the build user. The
        # Linux sandbox always builds in /build as nixbld. Darwin builds in a
        # new directory, as one of several users, so the switch records the
        # Linux values, and two builds agree.
        postInstall = ''
          top="''${NIX_BUILD_TOP%/}/"
          grep -rlIFZ "$top" "$out/_opam/.opam-switch" | xargs -0 -r sed -i "s|$top|/build/|g"
          sed -i 's/^  user: ".*"$/  user: "nixbld"/' "$out/_opam/.opam-switch/switch-config"
        '';
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
  fetches = checked.entries;
}
