# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The opam-purifier command.
  # The default package overlay passes the source of the purifier library.
  cli = callPackage ./cli {
    purifierSource = null;
    version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../version.txt);
  };
}
