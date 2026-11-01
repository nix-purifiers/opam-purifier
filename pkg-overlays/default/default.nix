# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.opam-purifier` (`.cli`), and the builder `pkgs.buildOpamProject`
# (nix/lib/build-opam-project.nix) beside them, where nixpkgs keeps its
# own builders, so a package written for callPackage takes it by name. The
# command takes the source of the purifier library of this flake's closure,
# for the builds it runs outside a flake, and the builder takes the
# library itself. A consumer that lists this flake in `projects` holds the
# overlay as `opam-purifier/default`, which its package sets apply by
# default.
{ closure-lib, closure-inputs, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "opam-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      opam-purifier = added.opam-purifier // {
        cli = added.opam-purifier.cli.override { purifierSource = closure-inputs.purifier; };
      };
      buildOpamProject = final.callPackage ../../nix/lib/build-opam-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
