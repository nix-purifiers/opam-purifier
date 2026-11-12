# SPDX-License-Identifier: MIT
#
# The `opam-purifier` scope that the default package overlay adds to the
# package set. `lib` here is the library this flake composes, which holds
# the purifier library.
{ callPackage, lib, ... }:
{
  # The builder of the purifier contract (pkgs/build-opam-project/default.nix).
  buildOpamProject = callPackage ./build-opam-project {
    inherit (lib) purifier;
  };
  # The `opam-purifier` command. It builds outside a flake with the source
  # of the purifier library, which the default package overlay passes.
  opam-purifier = callPackage ./opam-purifier {
    version = import ./version.nix;
    purifierSource = null;
  };
}
