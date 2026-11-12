# SPDX-License-Identifier: MIT
#
# What the opam-purifier command builds for a project, outside a flake:
# project.nix on the nixpkgs and the purifier library the command was
# built with. The command selects an attribute with `-A`, such as
# `switch` for the lock run, `state` and `shell` for `prefetch`, and
# `release` for `publish`.
{
  src,
  lockFile,
  # A directory that holds opam's lock files, or null for the ones in `src`.
  opamLocked ? null,
  # The nixpkgs the command was built with.
  nixpkgs,
  # The source of the purifier library the command was built with.
  purifierSource,
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs { inherit system; };
  purifier = import purifierSource { inherit (pkgs) lib; };
in
import ../build-opam-project/project.nix { inherit purifier; } {
  inherit
    pkgs
    src
    lockFile
    opamLocked
    ;
}
