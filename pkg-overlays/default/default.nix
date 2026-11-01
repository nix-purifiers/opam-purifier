# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.opam-purifier`, made with lib.makeScope, which holds the
# packages of pkgs/. `.buildOpamProject` is the builder
# (nix/lib/build-opam-project.nix) and `.opam-purifier` is the command, to
# which the overlay passes the source of the purifier library of this
# flake's closure, for the builds the command runs outside a flake. A
# package in an overlay takes the scope by name, as `{ opam-purifier }:`,
# and `opam-purifier.overrideScope` replaces what the scope shares. A
# consumer that lists this flake in `projects` holds the overlay as
# `opam-purifier/default`, which its package sets apply by default.
{ closure-lib, closure-inputs, ... }:
let
  scopeOverlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "opam-purifier";
in
{
  overlay =
    final: prev:
    let
      added = scopeOverlay final prev;
    in
    added
    // {
      opam-purifier = added.opam-purifier.overrideScope (
        self: super: {
          opam-purifier = super.opam-purifier.override { purifierSource = closure-inputs.purifier; };
        }
      );
    };
}
