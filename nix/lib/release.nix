# SPDX-License-Identifier: MIT
#
# What `opam-purifier publish` builds: the release archive of one package
# of the project, the same derivation as `releases.<name>` of the builder.
{
  src,
  name,
  version,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs { inherit system; };
in
pkgs.callPackage ./release-archive.nix {
  src = import ./release-source.nix {
    inherit (pkgs) lib;
    inherit src;
  };
  inherit name version;
}
