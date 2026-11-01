# SPDX-License-Identifier: MIT
#
# What `opam-purifier install` builds for the interactive mode: the
# offline state of the lockfile for this machine, the same derivation the
# sandboxed build uses. The CLI builds it with an out-link, which is the
# GC root that keeps every locked file alive.
{
  lockFile,
  system,
  # The nixpkgs the CLI was built with.
  nixpkgs,
}:
(import nixpkgs { inherit system; }).callPackage ./state.nix { inherit lockFile system; }
