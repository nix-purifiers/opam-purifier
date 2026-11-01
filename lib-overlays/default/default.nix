# SPDX-License-Identifier: MIT
#
# The `opam-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildOpamProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    opam-purifier = prev.opam-purifier or { };
  };

}
