# SPDX-License-Identifier: MIT
#
# What the lock run builds to record the outputs: the sandboxed switch of
# the project, from the lockfile the lock run has written so far. Its
# nix-support/opam-purifier-files/<name> lists what each package
# installs. The tests run in this build when the lock holds the test
# dependencies, so a lock never records a project whose tests fail.
{
  src,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs { inherit system; };
in
(pkgs.callPackage ./build-opam-project.nix { } { inherit src; }).switch
