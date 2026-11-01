# SPDX-License-Identifier: MIT
#
# readLock: the lock in memory of the purifier contract, from the
# lockfile `opam-purifier lock` writes. The flake's library has it as
# `lib.opam-purifier.readLock`. The result is
#
#   purifier  "opam-purifier"
#   entries   the download entries of the purifier library, the ones the
#             lockfile keeps and the ones derive.nix derives from the opam
#             files; each carries `systems`, the Nix systems that install
#             the package it belongs to, or null for every system
#   outputs   <name> = { version, files } for each package of the project
#   problems  why the lockfile cannot be used, each naming the command to
#             run
#
# The builder passes it to checkLock of the purifier library.
{ lib }:
{
  src,
  lockFile ? src + "/opam-purifier.lock.json",
  # A directory that holds opam's lock files, in place of the ones in `src`.
  opamLocked ? null,
}:
let
  read = import ./lock.nix { inherit lockFile src opamLocked; };
  usable = read.problems == [ ];
in
{
  purifier = "opam-purifier";
  inherit (read) problems;
  entries =
    if usable then
      (import ./derive.nix {
        inherit lib;
        inherit (read) lock;
      }).downloads
    else
      [ ];
  outputs =
    if usable then
      lib.listToAttrs (
        map (p: lib.nameValuePair p.name { inherit (p) version files; }) read.lock.packages
      )
    else
      { };
}
