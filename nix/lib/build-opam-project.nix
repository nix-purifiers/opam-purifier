# SPDX-License-Identifier: MIT
#
# buildOpamProject: the sandboxed build of an opam project, from the
# lockfile `opam-purifier lock` writes. The flake's library has it as
# `lib.opam-purifier.buildOpamProject`:
#
#   (lib.opam-purifier.buildOpamProject { inherit pkgs; src = ./.; }).packages.hello
#
# It takes the arguments project.nix describes, and returns
#
#   packages.<name>  the files the project's package <name> installs, as
#                    the lock run recorded them; `files.<path>` names
#                    each, and `executables.<name>` each one under bin/
#   tests            the build of the project with its tests, which opam
#                    runs as it installs each package
#   release          the source archive `opam-purifier publish` submits,
#                    at <name>-<version>.tar.gz
#   fetches          the purifier library entries the build fetches
{ purifier }:
args:
let
  project = import ./project.nix { inherit purifier; } args;
in
{
  inherit (project)
    packages
    tests
    release
    fetches
    ;
}
