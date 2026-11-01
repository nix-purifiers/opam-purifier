# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The opam-purifier command.
  cli = callPackage ./cli {
    version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../version.txt);
  };
}
