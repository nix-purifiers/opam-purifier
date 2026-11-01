# SPDX-License-Identifier: MIT
#
# The flake's checks: the CLI, and the sandboxed builds of the fixtures
# under tests/fixtures from their committed lockfiles, with a run of what
# they build. tests/interactive.sh covers what runs outside the sandbox:
# the lock run, `install`, `opam` and `publish`.
{
  pkgs,
  overlay,
  cli,
}:
let
  inherit (pkgs) lib runCommand;
  pkgs' = pkgs.extend overlay;

  hello = pkgs'.buildOpamProject { src = ./fixtures/hello; };
  workspace = pkgs'.buildOpamProject { src = ./fixtures/workspace; };

  # tests/fixtures/stale holds a copy of hello's opam file with a line
  # added, so hello's lockfile is stale for it.
  staleEval = builtins.tryEval (
    (pkgs'.buildOpamProject {
      src = ./fixtures/stale;
      lockFile = ./fixtures/hello/opam-purifier.lock.json;
    }).switch.drvPath
  );
in
{
  inherit cli;

  hello-switch = hello.switch;
  hello-package = hello.packages.hello;

  # The executable the lock recorded runs, and prints what the library
  # makes. The test of the fixture ran in the switch build.
  hello-runs = runCommand "hello-runs" { } ''
    out_text="$(${hello.packages.hello.executables.hello})"
    [ "$out_text" = "Hello, Nix!" ] || { echo "unexpected output: $out_text" >&2; exit 1; }
    touch $out
  '';

  # Every file the lock recorded is in the package, the library among
  # them, and the names are known at evaluation.
  hello-outputs =
    assert hello.packages.hello.files ? "lib/hello/META";
    assert hello.packages.hello.executables ? hello;
    runCommand "hello-outputs" { } ''
      ${lib.concatMapStrings (f: ''
        test -e ${lib.escapeShellArg f}
      '') (lib.attrValues hello.packages.hello.files)}
      touch $out
    '';

  # The release archive of the builder is the one `opam-purifier publish`
  # builds (nix/lib/release.nix), byte for byte, from a copy of the source
  # at another store path.
  hello-release =
    let
      copy = builtins.path {
        path = ./fixtures/hello;
        name = "hello-copy";
      };
      published = import ../nix/lib/release.nix {
        src = copy;
        name = "hello";
        version = "0.1.0";
        nixpkgs = pkgs.path;
        inherit (pkgs.stdenv.hostPlatform) system;
      };
    in
    runCommand "hello-release" { } ''
      cmp ${hello.releases.hello}/hello-0.1.0.tar.gz ${published}/hello-0.1.0.tar.gz
      tar -tzf ${hello.releases.hello}/hello-0.1.0.tar.gz | grep -qx 'hello-0.1.0/hello.opam'
      touch $out
    '';

  # A lockfile made from other opam files fails evaluation.
  hello-stale =
    assert !staleEval.success;
    runCommand "hello-stale" { } "touch $out";

  workspace-switch = workspace.switch;

  # beta runs on alpha (a local package), base64 (a git pin) and uutf (a
  # URL pin).
  workspace-runs = runCommand "workspace-runs" { } ''
    out_text="$(${workspace.packages.beta.executables.beta})"
    [ "$out_text" = "Hello from alpha (16 characters)" ] || { echo "unexpected output: $out_text" >&2; exit 1; }
    touch $out
  '';

  workspace-outputs =
    assert workspace.packages.alpha.files ? "lib/alpha/META";
    assert workspace.packages.beta.executables ? beta;
    runCommand "workspace-outputs" { } "touch $out";
}
