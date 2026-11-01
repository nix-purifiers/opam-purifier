# SPDX-License-Identifier: MIT
#
# buildOpamProject: the sandboxed build of an opam project, from the
# lockfile `opam-purifier lock` writes.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# opam-purifier overlay (`overlays.default`) adds it to the package set in
# the scope `opam-purifier`, so a package written for callPackage takes it
# through the scope:
#
#   { opam-purifier }: (opam-purifier.buildOpamProject { src = ./.; }).packages.hello
#
# and `opam-purifier.buildOpamProject.override` replaces what it takes. It
# takes `pkgs` because fetchEntry of the purifier library and the system
# packages named by the depexts need the whole set. The builder takes the
# arguments project.nix describes, and returns
#
#   packages.<name>  the files the project's package <name> installs, as
#                    the lock run recorded them; `files.<path>` names
#                    each, and `executables.<name>` each one under bin/
#   tests            the build of the project with its tests, which opam
#                    runs as it installs each package
#   release          the source archive `opam-purifier publish` submits,
#                    at <name>-<version>.tar.gz
#   fetches          the purifier library entries the build fetches
{ pkgs, purifier }:
args:
let
  project = import ./project.nix { inherit purifier; } (args // { inherit pkgs; });
in
{
  inherit (project)
    packages
    tests
    release
    fetches
    ;
}
