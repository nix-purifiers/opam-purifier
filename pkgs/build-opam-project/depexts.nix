# SPDX-License-Identifier: MIT
#
# The packages a lock's depexts name for a system. opam's metadata names
# the NixOS system packages as nixpkgs attributes, sometimes nested ones.
{ lib, pkgs }:
solution:
map (
  attr:
  lib.attrByPath (lib.splitString "." attr)
    (throw "opam-purifier: a locked package needs the system package `${attr}`, which this package set does not have; pass it in `buildInputs`.")
    pkgs
) solution.depexts
