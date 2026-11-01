# SPDX-License-Identifier: MIT
#
# The source of a release archive: the project root without version
# control, opam's local switch, the purifier's state and build outputs.
# The builder's `releases.<name>` and `opam-purifier publish` both take
# the source from here, so they make the same archive, byte for byte.
{ lib, src }:
builtins.path {
  path = src;
  name = "opam-release-source";
  filter =
    path: type:
    let
      base = baseNameOf path;
    in
    !(
      base == ".git"
      || base == "_opam"
      || base == "_build"
      || base == ".opam-purifier"
      || lib.hasPrefix "result" base
    );
}
