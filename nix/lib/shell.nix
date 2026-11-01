# SPDX-License-Identifier: MIT
#
# The environment the interactive mode runs opam in: the tools of the
# sandboxed build (a C toolchain, make, opam and what it runs to unpack and
# copy sources) and the system packages the lock's depexts name. The CLI
# runs `install` and `opam-purifier opam` inside it with nix-shell, so a
# local switch builds with the same tools as the Nix build.
{
  lockFile,
  system,
  # The nixpkgs the CLI was built with.
  nixpkgs,
}:
let
  pkgs = import nixpkgs { inherit system; };
  lock = import ./lock.nix { inherit lockFile; };
in
pkgs.mkShell {
  packages = [
    pkgs.opam
    pkgs.rsync
    pkgs.unzip
    pkgs.which
    pkgs.pkg-config
  ]
  ++ import ./depexts.nix {
    inherit (pkgs) lib;
    inherit pkgs;
  } (lock.forSystem system);
}
