# SPDX-License-Identifier: MIT
#
# The `opam-purifier` library namespace: the builder buildOpamProject
# (nix/lib/build-opam-project.nix), on the purifier library of this
# flake's closure. A consumer that lists this flake in `projects` holds
# it as `opam-purifier/default`, and its library then has
# `lib.opam-purifier.buildOpamProject`.
{ closure-lib, ... }:
{

  overlay = final: prev: {
    opam-purifier = (prev.opam-purifier or { }) // {
      buildOpamProject = import ../../nix/lib/build-opam-project.nix {
        inherit (closure-lib) purifier;
      };
    };
  };

}
