# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };
  };

  # The scope is the `default` entry of this flake's package overlay
  # registry (pkg-overlays/). The `packages` output holds the derivations
  # of the scope, because the scope also holds the builder, which is a
  # function.
  purifier.scope = "opam-purifier";

  # `nix run github:nix-purifiers/opam-purifier -- lock` locks the project
  # in the current directory.
  perSystem =
    { config, ... }:
    {
      packages.default = config.packages.opam-purifier;
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              inherit (self.lib.opam-purifier) readLock;
              inherit (self.lib) purifier;
              cli = self.packages.${system}.opam-purifier;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
