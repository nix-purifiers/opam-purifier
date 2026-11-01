# SPDX-License-Identifier: MIT
#
# The `opam-purifier` library namespace: the builder buildOpamProject
# (nix/lib/build-opam-project.nix), on the purifier library of this
# flake's closure, and readLock (nix/lib/read-lock.nix), the lock in
# memory of the purifier contract. A consumer that lists this flake in
# `projects` holds it as `opam-purifier/default`, and its library then
# has `lib.opam-purifier.buildOpamProject` and `lib.opam-purifier.readLock`.
{ closure-lib, ... }:
{

  overlay = final: prev: {
    opam-purifier = (prev.opam-purifier or { }) // {
      buildOpamProject = import ../../nix/lib/build-opam-project.nix {
        inherit (closure-lib) purifier;
      };
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
