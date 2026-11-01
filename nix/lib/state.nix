# SPDX-License-Identifier: MIT
#
# The offline state of a lockfile for one system: everything opam reads,
# so that it installs the locked packages with no network. Both the
# sandboxed build and `opam-purifier prefetch` use it.
#
# The state directory holds
#
#   repository/        an opam repository with the opam file of each
#                      locked package, and nothing else
#   download-cache/    opam's download cache: each locked archive at the
#                      path of its checksum, a link into the store
#   sources/           the locked checkouts of version-control sources
#   fetch-manifest     each locked URL and mirror, with its store path
#   bin/offline-fetch  opam's download command (OPAMFETCH): it serves the
#                      locked files from the manifest and fails for any
#                      other URL
#   bin/install-dependencies PREFIX
#                      sets up the opam root at $OPAMROOT, creates the
#                      switch at PREFIX and installs the locked packages
#   loop-bin/opam      the opam of the everyday loop, which names
#                      `opam-purifier lock` when an install fails
{
  pkgs,
  purifier,
  lock,
  system,
  # Passed to fetchEntry and tree of the purifier library.
  fetchers,
}:
let
  inherit (pkgs) lib writeText bash;
  solution = lock.forSystem system;

  fetch = purifier.fetchEntry ({ inherit pkgs; } // fetchers);

  # Every download at its path: the download cache and the checkouts.
  downloads = purifier.tree (
    {
      inherit pkgs;
      name = "opam-purifier-downloads";
      entries = lock.downloads;
    }
    // fetchers
  );

  repositoryFiles = lib.concatMapStrings (
    entry: "${entry.path}\t${writeText (lock.storeName (baseNameOf entry.path)) entry.contents}\n"
  ) lock.repository;

  # Every URL a file can be asked for: its upstream URL and its mirrors,
  # among them opam's own cache.
  fetchManifest = lib.concatMapStrings (
    download:
    let
      path = fetch download;
    in
    lib.concatMapStrings (url: "${url}\t${path}\n") ([ download.url ] ++ download.mirrors)
  ) lock.files;

  # The pins, as `opam pin add` commands. A pin of a project directory
  # takes its path below the project root, which install-dependencies
  # reads from its second argument.
  pinCommands = lib.concatMapStrings (
    pin:
    if pin.kind == "project" then
      ''
        opam pin add --no-action --kind=path ${lib.escapeShellArg pin.package} "$project"/${lib.escapeShellArg pin.path}
      ''
    else if pin.kind == "source" then
      # opam copies a path pin's files with their permissions and then
      # replaces them, so it pins a writable copy of the checkout.
      ''
        mkdir -p "$OPAMROOT/purifier-pins"
        cp -r -H --no-preserve=mode "$state"/${lib.escapeShellArg pin.path} "$OPAMROOT/purifier-pins/"${lib.escapeShellArg pin.package}
        opam pin add --no-action --kind=path ${lib.escapeShellArg pin.package} "$OPAMROOT/purifier-pins/"${lib.escapeShellArg pin.package}
      ''
    else
      ''
        opam pin add --no-action ${lib.escapeShellArg pin.package} ${lib.escapeShellArg pin.url}
      ''
  ) lock.pins;

  offlineFetch = ''
    #!${bash}/bin/bash
    # opam's download command: serves a locked file by its URL.
    set -euo pipefail
    url="$1"
    out="$2"
    while IFS=$'\t' read -r locked path; do
      if [ "$locked" = "$url" ]; then
        cp "$path" "$out"
        exit 0
      fi
    done < @state@/fetch-manifest
    echo "opam-purifier: $url is not in the lockfile; run \`opam-purifier lock\`" >&2
    exit 1
  '';

  loopOpam = ''
    #!${bash}/bin/bash
    # opam, on the root that `opam-purifier prefetch` set up. That root has
    # only the locked packages, so an install of anything else fails.
    if ${pkgs.opam}/bin/opam "$@"; then
      exit 0
    else
      status=$?
    fi
    case "''${1:-}" in
      install | upgrade | reinstall | pin)
        echo "opam-purifier: opam installs only what the lockfile holds. To add a dependency, add it to the opam file, then run \`opam-purifier lock\` and \`opam-purifier prefetch\`. For an editor or another tool, run \`opam-purifier lock --tool PACKAGE\`." >&2
        ;;
    esac
    exit "$status"
  '';

  patchShebangs = ''
    #!${bash}/bin/bash
    # Rewrites the interpreter of each executable script below the current
    # directory to the one of the same name on PATH. `#!/usr/bin/env NAME`
    # becomes the NAME on PATH; interpreters already in the store stay.
    set -euo pipefail
    find . -type f -perm -0100 -print0 | while IFS= read -r -d "" file; do
      [ "$(head -c 2 "$file")" = '#!' ] || continue
      read -r interpreter first rest < <(head -n 1 "$file" | tail -c +3) || true
      case "$interpreter" in
        "" | /nix/store/*) continue ;;
        */env)
          case "$first" in
            "" | -* | *=*) continue ;;
          esac
          new="$(command -v "$first" || true)"
          args="$rest"
          ;;
        *)
          new="$(command -v "$(basename "$interpreter")" || true)"
          args="$first''${rest:+ $rest}"
          ;;
      esac
      [ -n "$new" ] || continue
      line="#!$new''${args:+ $args}"
      sed -i "1s|.*|$(printf '%s' "$line" | sed 's/[|&\\]/\\&/g')|" "$file"
    done
  '';

  installDependencies = ''
    #!${bash}/bin/bash
    # Sets up the opam root at $OPAMROOT and creates the switch at $1,
    # with the locked packages installed. $2 is the project root that
    # pins of project directories are below; the default is $1. A third
    # argument `--with-tools` also installs the tools the lock holds.
    set -euo pipefail
    state=@state@
    prefix="$1"
    project="''${2:-$1}"
    opam init --bare --disable-sandboxing --no-setup purifier "$state/repository"
    # The Nix sandbox has no /usr/bin/env or /bin/bash, so opam runs
    # bin/patch-shebangs in each source tree before building it. The
    # script points shebang lines at interpreters on PATH. opam has a hook
    # for the same job, but it writes that hook only when it runs on NixOS.
    opam option --global 'pre-build-commands=["'"$state"'/bin/patch-shebangs"]'
    # The download cache is a writable tree of links into the store, since
    # opam adds to it.
    mkdir -p "$OPAMROOT/download-cache"
    cp -r --no-preserve=mode "$state/download-cache/." "$OPAMROOT/download-cache/"
    opam switch create "$prefix" --empty
    export OPAMSWITCH="$prefix"
    ${pinCommands}
    ${lib.optionalString (solution.install != [ ]) ''
      opam install ${lib.escapeShellArgs solution.install}
    ''}
    # The tools the lock holds for the interactive mode (opam-purifier lock
    # --tool), when the third argument asks for them.
    if [ "''${3:-}" = --with-tools ]; then
      ${lib.optionalString (solution.tools or [ ] != [ ]) ''
        opam install ${lib.escapeShellArgs solution.tools}
      ''}
      :
    fi
  '';
in
pkgs.runCommand "opam-purifier-state"
  {
    inherit
      repositoryFiles
      fetchManifest
      offlineFetch
      patchShebangs
      installDependencies
      loopOpam
      ;
    passAsFile = [
      "repositoryFiles"
      "fetchManifest"
      "offlineFetch"
      "patchShebangs"
      "installDependencies"
      "loopOpam"
    ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = {
      inherit lock solution downloads;
    };
  }
  ''
    mkdir -p $out/repository $out/download-cache $out/sources $out/bin $out/loop-bin
    echo 'opam-version: "2.0"' > $out/repository/repo
    while IFS=$'\t' read -r rel target; do
      mkdir -p "$(dirname "$out/repository/$rel")"
      cp "$target" "$out/repository/$rel"
    done < "$repositoryFilesPath"
    for dir in download-cache sources; do
      if [ -d ${downloads}/$dir ]; then
        cp -r ${downloads}/$dir/. $out/$dir/
      fi
    done
    cp "$fetchManifestPath" $out/fetch-manifest
    substitute "$offlineFetchPath" $out/bin/offline-fetch --subst-var-by state $out
    cp "$patchShebangsPath" $out/bin/patch-shebangs
    substitute "$installDependenciesPath" $out/bin/install-dependencies --subst-var-by state $out
    cp "$loopOpamPath" $out/loop-bin/opam
    chmod +x $out/bin/* $out/loop-bin/*
  ''
