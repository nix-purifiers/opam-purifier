# SPDX-License-Identifier: MIT
#
# The `opam-purifier` library namespace: readLock (nix/lib/read-lock.nix),
# the lock in memory of the purifier contract. A consumer that lists this
# flake in `projects` holds it as `opam-purifier/default`, and its library
# then has `lib.opam-purifier.readLock`. The builder needs a package set,
# so it is the package `buildOpamProject` of the default package overlay.
{ ... }:
{

  overlay = final: prev: {
    opam-purifier = (prev.opam-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
