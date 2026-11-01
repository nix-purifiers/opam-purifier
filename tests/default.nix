# SPDX-License-Identifier: MIT
#
# The flake's checks: the CLI, the sandboxed builds of the fixtures under
# tests/fixtures and of a real project from their committed lockfiles,
# with a run of what they build, and the conformance checks of the
# purifier contract that the sandbox can run. tests/interactive.sh covers
# what runs outside the sandbox: the lock run, `prefetch` and `publish`.
{
  pkgs,
  buildOpamProject,
  # The purifier library, for the check that builds the internals of
  # project.nix.
  purifier,
  cli,
}:
let
  inherit (pkgs) lib runCommand;
  build = args: buildOpamProject ({ inherit pkgs; } // args);

  hello = build { src = ./fixtures/hello; };
  workspace = build { src = ./fixtures/workspace; };

  # A real project: mirage/ocaml-uri at v4.4.0, with uri, uri-re and
  # uri-sexp. Its lock leaves the benchmark package out with `--only`. The
  # source comes from GitHub by hash, and the lockfile it was locked with
  # is kept outside it, under real-world/uri.
  uri = build {
    src = builtins.fetchTarball {
      url = "https://github.com/mirage/ocaml-uri/archive/c336c796f4deb8979a4c7ceea3bef34b46240623.tar.gz";
      sha256 = "1y2i0q7jpavmrg0ga1hsiv6bvxvrm5scm8ax0j4gpyr2qih4h9i8";
    };
    lockFile = ./real-world/uri/opam-purifier.lock.json;
  };

  helloLock = ./fixtures/hello/opam-purifier.lock.json;
  withoutLockfile =
    path:
    builtins.path {
      inherit path;
      name = "${baseNameOf path}-without-lockfile";
      filter = p: type: baseNameOf p != "opam-purifier.lock.json";
    };

  # Evaluates the lockfile reader of the library on a lockfile and a
  # project inside the sandbox, and expects the evaluation to fail with a
  # message that contains `pattern`. `setup` writes $TMPDIR/lock.json and
  # $TMPDIR/src.
  expectLockFailure =
    name: pattern: setup:
    runCommand name { nativeBuildInputs = [ pkgs.nix ]; } ''
      export HOME="$TMPDIR" NIX_STATE_DIR="$TMPDIR/state" NIX_LOG_DIR="$TMPDIR/log"
      export NIX_CONF_DIR="$TMPDIR/conf"
      mkdir -p "$NIX_CONF_DIR"
      cp -r ${../nix/lib} "$TMPDIR/lib"
      ${setup}
      if nix-instantiate --eval --strict --readonly-mode --store dummy:// \
        -E "(import $TMPDIR/lib/lock.nix { lockFile = $TMPDIR/lock.json; src = $TMPDIR/src; }).packages" \
        > "$TMPDIR/out" 2>&1; then
        echo "the evaluation succeeded; expected a failure that says: "${lib.escapeShellArg pattern} >&2
        exit 1
      fi
      if ! grep -qF -- ${lib.escapeShellArg pattern} "$TMPDIR/out"; then
        echo "the evaluation failed without saying: "${lib.escapeShellArg pattern} >&2
        cat "$TMPDIR/out" >&2
        exit 1
      fi
      touch $out
    '';
  helloSrc = ''
    cp -r ${./fixtures/hello} "$TMPDIR/src"
    chmod -R u+w "$TMPDIR/src"
    rm "$TMPDIR/src/opam-purifier.lock.json"
  '';

  # hello's lockfile without the archive of one package, re-hashed so that
  # it is intact. The fetch of that archive fails when opam asks for it.
  missing =
    let
      original = builtins.fromJSON (builtins.readFile helloLock);
      dropped = lib.findFirst (
        d: d ? url && lib.hasInfix "/fmt-" d.url
      ) (throw "the hello fixture has no archive of fmt") original.downloads;
      edited = removeAttrs original [ "lockHash" ] // {
        downloads = lib.filter (d: d != dropped) original.downloads;
      };
      text = builtins.toJSON (
        edited // { lockHash = "sha256:${builtins.hashString "sha256" (builtins.toJSON edited)}"; }
      );
    in
    {
      inherit dropped;
      project = import ../nix/lib/project.nix { inherit purifier; } {
        inherit pkgs;
        src = withoutLockfile ./fixtures/hello;
        lockFile = builtins.toFile "opam-purifier.lock.json" "${text}\n";
      };
    };
in
{
  inherit cli;

  hello-package = hello.packages.hello;
  hello-tests = hello.tests;

  # The executable the lock recorded runs, and prints what the library
  # makes.
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

  # The release archive is the same, byte for byte, from a copy of the
  # source at another store path, and holds the opam file under
  # hello-0.1.0/.
  hello-release =
    let
      copy = build {
        src = builtins.path {
          path = ./fixtures/hello;
          name = "hello-copy";
        };
      };
    in
    runCommand "hello-release" { } ''
      cmp ${hello.release}/hello-0.1.0.tar.gz ${copy.release}/hello-0.1.0.tar.gz
      tar -tzf ${hello.release}/hello-0.1.0.tar.gz | grep -qx 'hello-0.1.0/hello.opam'
      touch $out
    '';

  # `fetches` lists the download entries the lockfile holds.
  hello-fetches =
    assert hello.fetches == (builtins.fromJSON (builtins.readFile helloLock)).downloads;
    runCommand "hello-fetches" { } "touch $out";

  workspace-package = workspace.packages.beta;

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

  # ocaml-uri builds with its tests. The fuzz test of uri-re uses uri and
  # crowbar, and uri-re's opam file declares neither.
  real-world-uri-tests = uri.tests;

  real-world-uri-outputs =
    assert uri.packages.uri.files ? "lib/uri/META";
    assert uri.packages.uri-re.files ? "lib/uri-re/META";
    assert uri.packages.uri-sexp.files ? "lib/uri-sexp/META";
    runCommand "real-world-uri-outputs" { } ''
      test -e ${uri.packages.uri.files."lib/uri/META"}
      touch $out
    '';

  # A lockfile older than the project's opam files: tests/fixtures/stale
  # holds hello's opam file with a line added.
  conformance-stale = expectLockFailure "conformance-stale" "run `opam-purifier lock`" ''
    cp ${helloLock} "$TMPDIR/lock.json"
    mkdir "$TMPDIR/src"
    cp ${./fixtures/stale/hello.opam} "$TMPDIR/src/hello.opam"
  '';

  # A lockfile with a changed hash and the lockHash it was written with.
  conformance-tampered =
    expectLockFailure "conformance-tampered"
      "was changed after `opam-purifier lock` wrote it (its lockHash does not match its content); run `opam-purifier lock`"
      ''
        sed '0,/"hash": "sha256-/s//"hash": "sha256-AAAA/' ${helloLock} > "$TMPDIR/lock.json"
        cmp -s ${helloLock} "$TMPDIR/lock.json" && { echo "the edit changed nothing" >&2; exit 1; }
        ${helloSrc}
      '';

  # A lockfile that is not whole: its first 200 bytes.
  conformance-malformed =
    expectLockFailure "conformance-malformed" "run `opam-purifier lock` to write it again"
      ''
        head -c 200 ${helloLock} > "$TMPDIR/lock.json"
        ${helloSrc}
      '';

  # A project with no lockfile fails at evaluation. A lockfile without the
  # archive of a package opam installs fails when opam asks for it, and
  # the download command names the URL and the command to run.
  conformance-missing =
    let
      noLockfile =
        expectLockFailure "conformance-missing-lockfile" "does not exist; run `opam-purifier lock`"
          helloSrc;
    in
    runCommand "conformance-missing" { } ''
      if ${missing.project.state}/bin/offline-fetch ${lib.escapeShellArg missing.dropped.url} "$TMPDIR/file" 2> "$TMPDIR/err"; then
        echo "the download of a URL the lockfile leaves out succeeded" >&2
        exit 1
      fi
      grep -qF ${lib.escapeShellArg "${missing.dropped.url} is not in the lockfile; run `opam-purifier lock`"} "$TMPDIR/err"
      # The check of the missing lockfile is a dependency of this one.
      test -e ${noLockfile}
      touch $out
    '';

  # CI runs `nix build --rebuild` on this check, the switch of hello,
  # and fails when the second build differs.
  conformance-rebuild = hello.packages.hello.switch;

  # hello, from a source that holds no lockfile and a lockfile kept
  # outside it.
  conformance-external =
    let
      external = build {
        src = withoutLockfile ./fixtures/hello;
        lockFile = helloLock;
      };
    in
    runCommand "conformance-external" { } ''
      [ "$(${external.packages.hello.executables.hello})" = "Hello, Nix!" ]
      touch $out
    '';
}
