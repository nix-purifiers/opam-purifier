#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# What runs outside the Nix sandbox, on copies of the fixtures. Each
# section is a function; arguments name the sections to run, and the
# default is all of them. CI runs the conformance sections as jobs of the
# same name.
#
#   conformance-relock   a lock of each fixture, and of ocaml-uri with its
#                        lockfile outside the source, against the pinned
#                        repository its lockfile names, writes the
#                        committed lockfile byte for byte
#   conformance-offline  after `prefetch`, with the network cut off, dune
#                        builds, runs and tests the project, opam refuses a
#                        package the lock does not hold and names the
#                        command to run, and a tool locked with --tool is
#                        installed
#   conformance-update   `update` moves a package of a git repository that
#                        `lock` keeps at the commit the lockfile records, and
#                        the result builds from a lockfile that passes the
#                        stale check
#   conformance-rebuild  `nix build --rebuild` of the switch of hello gives
#                        the same output
#   lockfiles            with opam's own lock file beside the opam file,
#                        the lock run solves with --locked, to the same
#                        versions
#   publish              the archive Nix built, served from a local server,
#                        goes into a repository checkout and to a stand-in
#                        for opam-publish; a different archive at the URL
#                        is refused
#   negative             the commands fail on a tampered, malformed or
#                        stale lockfile with a message that names the
#                        command to run, and a wrong download hash fails
#                        the build
#   repository           a custom repository whose package has a git
#                        source, served over HTTP, locked with --repo and
#                        built
#   darcs                two Darcs repositories made here and served over
#                        HTTP, one pinned by tag and one by its head,
#                        locked and built
#   hg                   a Mercurial repository served by `hg serve`,
#                        pinned by its default branch, which the lock
#                        resolves to a node
#
# It runs from the repository root and needs nix with flakes and network
# access. conformance-offline also needs a way to cut the network off:
# unprivileged user namespaces, or sudo.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
server_pids=()
cleanup() {
  for pid in "${server_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

cli="$(nix build --no-link --print-out-paths "$root#cli")/bin/opam-purifier"
python="$(nix build --no-link --print-out-paths 'nixpkgs#python3')/bin/python3"
darcs="$(nix build --no-link --print-out-paths 'nixpkgs#darcs')/bin/darcs"
hg="$(nix build --no-link --print-out-paths 'nixpkgs#mercurial')/bin/hg"
git="$(nix build --no-link --print-out-paths 'nixpkgs#git')/bin/git"
util_linux="$(nix build --no-link --print-out-paths 'nixpkgs#util-linux.bin')/bin"
curl="$(nix build --no-link --print-out-paths 'nixpkgs#curl.bin')/bin/curl"
tar="$(nix build --no-link --print-out-paths 'nixpkgs#gnutar')/bin/tar"
gzip="$(nix build --no-link --print-out-paths 'nixpkgs#gzip^out')/bin/gzip"
author="nix-purifiers <nix-purifiers@example.invalid>"

fixture() {
  rm -rf "$work/$1"
  cp -r "$root/tests/fixtures/$1" "$work/$1"
  chmod -R u+w "$work/$1"
  echo "$work/$1"
}

# Builds an attribute of buildOpamProject for a project directory, with
# the flake's library, and prints the store path.
build() {
  local src="$1" attr="$2"
  nix build --no-link --print-out-paths --impure --expr "
    let flake = builtins.getFlake \"git+file://$root\";
        pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}.extend flake.overlays.default;
    in (pkgs.buildOpamProject { src = $src; }).$attr"
}

# Runs a command with the network cut off: in a new network namespace,
# as the current user.
offline() {
  if "$util_linux/unshare" --user --map-root-user --net true 2>/dev/null; then
    "$util_linux/unshare" --user --map-root-user --net -- env OPAMROOTISOK=1 "$@"
  else
    sudo --preserve-env env "PATH=$PATH" "$util_linux/unshare" --net -- \
      "$util_linux/setpriv" --reuid="$(id -u)" --regid="$(id -g)" --clear-groups -- "$@"
  fi
}

# Runs a script in the environment of the development loop of a project.
in_env() {
  local dir="$1" script="$2"
  bash -c "
    set -euo pipefail
    cd '$dir'
    source .opam-purifier/env.sh
    $script"
}

# Runs a script in the environment of the development loop of a project,
# with the network cut off.
in_loop() {
  local dir="$1" script="$2"
  offline bash -c "
    set -euo pipefail
    cd '$dir'
    if (exec 3<>/dev/tcp/1.1.1.1/443) 2>/dev/null; then
      echo 'the network is still reachable' >&2
      exit 1
    fi
    source .opam-purifier/env.sh
    $script"
}

# Expects a command to fail with a message matching a pattern.
expect_failure() {
  local pattern="$1"
  shift
  if "$@" >"$work/failure.log" 2>&1; then
    echo "expected a failure matching '$pattern' from: $*" >&2
    exit 1
  fi
  if ! grep -q -- "$pattern" "$work/failure.log"; then
    echo "the failure of '$*' did not say '$pattern':" >&2
    tail -20 "$work/failure.log" >&2
    exit 1
  fi
}
free_port() {
  "$python" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Serves a directory over HTTP on a free local port and prints the port.
serve() {
  local dir="$1" port
  port="$(free_port)"
  "$python" -m http.server --bind 127.0.0.1 --directory "$dir" "$port" >/dev/null 2>&1 &
  server_pids+=("$!")
  for _ in $(seq 50); do
    if "$python" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port/')" 2>/dev/null; then
      echo "$port"
      return
    fi
    sleep 0.2
  done
  echo "the HTTP server on port $port did not start" >&2
  exit 1
}

# Writes a small dune library package with its opam file into a directory.
write_package() {
  local dir="$1" name="$2" origin="$3"
  mkdir -p "$dir"
  cat >"$dir/dune-project" <<'EOF'
(lang dune 3.0)
EOF
  cat >"$dir/$name.opam" <<EOF
opam-version: "2.0"
name: "$name"
version: "1"
synopsis: "A $origin fixture for opam-purifier"
maintainer: "nix-purifiers"
depends: [ "ocaml" "dune" ]
build: [ ["dune" "build" "-p" name] ]
EOF
  cat >"$dir/dune" <<EOF
(library (name $name) (public_name $name))
EOF
  echo "let message = \"$name from $origin\"" >"$dir/$name.ml"
}

# Writes a project with one executable on the given packages.
write_project() {
  local dir="$1" name="$2" depends="$3" pins="$4" main="$5"
  mkdir -p "$dir/bin"
  cat >"$dir/dune-project" <<'EOF'
(lang dune 3.0)
EOF
  cat >"$dir/$name.opam" <<EOF
opam-version: "2.0"
name: "$name"
version: "1"
synopsis: "An opam-purifier test project"
maintainer: "nix-purifiers"
depends: [ "ocaml" "dune" $depends ]
pin-depends: [ $pins ]
build: [ ["dune" "build" "-p" name] ]
EOF
  cat >"$dir/bin/dune" <<EOF
(executable (name $name) (public_name $name) (libraries ${depends//\"/}))
EOF
  echo "$main" >"$dir/bin/$name.ml"
}

# Rewrites a lockfile with a Python expression on `lock`, then writes the
# lockHash for the result, the way a lockfile edited on purpose and
# re-hashed would look.
rewrite_lock() {
  local file="$1" expression="$2" rehash="$3"
  "$python" - "$file" "$expression" "$rehash" "$cli" <<'EOF'
import importlib.machinery, importlib.util, json, pathlib, sys
file, expression, rehash, cli = sys.argv[1:]
script = pathlib.Path(cli).resolve().parent.parent / "libexec" / "opam-purifier.py"
loader = importlib.machinery.SourceFileLoader("op", str(script))
spec = importlib.util.spec_from_loader("op", loader)
op = importlib.util.module_from_spec(spec)
loader.exec_module(op)
lock = json.loads(pathlib.Path(file).read_text())
exec(expression)
if rehash == "rehash":
    lock["lockHash"] = op.lock_hash(lock)
pathlib.Path(file).write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n")
EOF
}

section_conformance-relock() {
  echo "== conformance-relock"
  local name dir
  for name in hello workspace; do
    dir="$(fixture "$name")"
    (cd "$dir" && "$cli" lock)
    cmp "$root/tests/fixtures/$name/opam-purifier.lock.json" "$dir/opam-purifier.lock.json"
  done
  # ocaml-uri, at the commit tests/default.nix builds, with its lockfile
  # outside the source.
  mkdir -p "$work/uri"
  "$curl" -fsSL https://github.com/mirage/ocaml-uri/archive/c336c796f4deb8979a4c7ceea3bef34b46240623.tar.gz |
    "$gzip" -dc | "$tar" -x -C "$work/uri" --strip-components=1
  cp "$root/tests/real-world/uri/opam-purifier.lock.json" "$work/uri.lock.json"
  chmod u+w "$work/uri.lock.json"
  (cd "$work/uri" && "$cli" lock --lockfile "$work/uri.lock.json")
  cmp "$root/tests/real-world/uri/opam-purifier.lock.json" "$work/uri.lock.json"
  [ ! -e "$work/uri/opam-purifier.lock.json" ]
}

section_conformance-offline() {
  echo "== conformance-offline"
  local dir
  dir="$(fixture hello)"
  (cd "$dir" && "$cli" prefetch)
  in_loop "$dir" '
    dune build
    [ "$(./_build/default/bin/main.exe)" = "Hello, Nix!" ]
    dune test'
  expect_failure 'opam-purifier lock --tool' in_loop "$dir" 'opam install --yes cmdliner'
  # A tool locked for the development loop is installed by prefetch, and the
  # sandboxed build leaves it out.
  (cd "$dir" && "$cli" lock --tool cmdliner)
  "$python" - "$dir/opam-purifier.lock.json" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
for system in lock["systems"].values():
    assert any(p.startswith("cmdliner.") for p in system["tools"]), system
    assert not any(p.startswith("cmdliner.") for p in system["install"]), system
EOF
  (cd "$dir" && "$cli" prefetch)
  in_loop "$dir" 'opam list --installed --short | grep -qx cmdliner'
}

section_conformance-rebuild() {
  echo "== conformance-rebuild"
  local system
  system="$(nix eval --impure --raw --expr builtins.currentSystem)"
  nix build --no-link "$root#checks.$system.conformance-rebuild"
  nix build --no-link --rebuild "$root#checks.$system.conformance-rebuild"
}

section_conformance-update() {
  echo "== conformance-update"
  local repo project
  commit_repo() {
    (cd "$repo" && "$git" add -A && "$git" -c user.name=nix-purifiers -c user.email=nix-purifiers@example.invalid commit --quiet -m "$1")
  }
  write_virtual() {
    mkdir -p "$repo/packages/lambda/lambda.$1"
    cat >"$repo/packages/lambda/lambda.$1/opam" <<EOF
opam-version: "2.0"
synopsis: "A package with no sources, version $1"
maintainer: "nix-purifiers"
EOF
  }
  # An opam repository in a git repository, with lambda.1 in it.
  repo="$work/update-repository"
  mkdir -p "$repo"
  echo 'opam-version: "2.0"' >"$repo/repo"
  (cd "$repo" && "$git" init --quiet -b main)
  write_virtual 1
  commit_repo "Add lambda 1"
  # A project that depends on lambda, with opam's own lock file at lambda.1.
  project="$work/update-project"
  mkdir -p "$project/bin"
  echo '(lang dune 3.0)' >"$project/dune-project"
  cat >"$project/up.opam" <<EOF
opam-version: "2.0"
name: "up"
version: "1"
synopsis: "An opam-purifier update test project"
maintainer: "nix-purifiers"
depends: [ "ocaml" "dune" "lambda" ]
build: [ ["dune" "build" "-p" name] ]
EOF
  echo '(executable (name up) (public_name up))' >"$project/bin/dune"
  echo 'let () = print_endline "up"' >"$project/bin/up.ml"
  local archive=https://github.com/ocaml/opam-repository/archive/2ffc3518756432a5bea7cda8ae467ea8b4e0362a.tar.gz
  (cd "$project" && "$cli" lock --repo "default=archive+$archive" --repo "custom=git+file://$repo")
  grep -q '"lambda.1"' "$project/opam-purifier.lock.json"
  # opam's own lock file for the project at these versions, which the build
  # writes, and a lock against it.
  cp "$(build "$project" packages.up.switch)/nix-support/opam-locked/up.opam.locked" "$project/up.opam.locked"
  chmod u+w "$project/up.opam.locked"
  grep -q '"lambda" {= "1"}' "$project/up.opam.locked"
  (cd "$project" && "$cli" lock)
  grep -q '"lambda.1"' "$project/opam-purifier.lock.json"
  # A new version appears in the repository. `lock` keeps the commit the
  # lockfile records, and so the version.
  write_virtual 2
  commit_repo "Add lambda 2"
  (cd "$project" && "$cli" lock)
  grep -q '"lambda.1"' "$project/opam-purifier.lock.json"
  # `update` moves it, and the result builds from a lockfile that passes
  # the stale check.
  (cd "$project" && "$cli" update lambda)
  grep -q '"lambda.2"' "$project/opam-purifier.lock.json"
  if grep -q '"lambda.1"' "$project/opam-purifier.lock.json"; then
    echo "update left lambda.1 in the lockfile" >&2
    exit 1
  fi
  grep -q '"lambda" {= "2"}' "$project/up.opam.locked"
  [ "$("$(build "$project" packages.up)/bin/up")" = "up" ]
  # Both lockfiles pass the stale check: `lock` finds nothing to change.
  cp "$project/opam-purifier.lock.json" "$work/update-after.json"
  (cd "$project" && "$cli" lock)
  cmp "$work/update-after.json" "$project/opam-purifier.lock.json"
  # A package that is not in the lockfile is refused.
  expect_failure 'nothing is not in' sh -c "cd '$project' && '$cli' update nothing"
}

section_lockfiles() {
  echo "== lockfiles"
  local dir
  dir="$(fixture hello)"
  (cd "$dir" && "$cli" prefetch)
  in_env "$dir" 'opam lock .'
  [ -f "$dir/hello.opam.locked" ]
  (cd "$dir" && "$cli" lock)
  "$python" - "$dir/opam-purifier.lock.json" "$dir/hello.opam.locked" <<'EOF'
import json, re, sys
lock = json.load(open(sys.argv[1]))
assert lock["options"]["locked"], lock["options"]
locked = dict(re.findall(r'"([^"]+)" \{= "([^"]+)"', open(sys.argv[2]).read()))
for system in lock["systems"].values():
    installs = dict(p.split(".", 1) for p in system["install"])
    for name, version in locked.items():
        if name in installs:
            assert installs[name] == version, (name, installs[name], version)
EOF
}

section_publish() {
  echo "== publish"
  local dir archive port url published
  dir="$(fixture hello)"
  # Without --url, publish builds the archive and prints its path.
  archive="$(cd "$dir" && "$cli" publish | sed -n 's|^opam-purifier: \(/nix/store/.*\.tar\.gz\)$|\1|p')"
  [ -f "$archive" ]
  mkdir -p "$work/served"
  cp --no-preserve=mode "$archive" "$work/served/"
  port="$(serve "$work/served")"
  url="http://127.0.0.1:$port/hello-0.1.0.tar.gz"
  mkdir -p "$work/repository"
  (cd "$dir" && "$cli" publish --url "$url" --repository "$work/repository")
  published="$work/repository/packages/hello/hello.0.1.0/opam"
  grep -q "src: \"$url\"" "$published"
  grep -q "sha256=$(sha256sum "$archive" | cut -d' ' -f1)" "$published"
  cat >"$work/opam-publish" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/opam-publish.args"
EOF
  chmod +x "$work/opam-publish"
  (cd "$dir" && OPAM_PURIFIER_OPAM_PUBLISH="$work/opam-publish" "$cli" publish --url "$url")
  head -n 1 "$work/opam-publish.args" | grep -qx "$url"
  echo tampered >>"$work/served/hello-0.1.0.tar.gz"
  expect_failure 'serves different bytes' sh -c "cd '$dir' && '$cli' publish --url '$url' --repository '$work/repository'"
}

section_negative() {
  echo "== negative"
  local dir wdir
  dir="$(fixture hello)"
  cp "$dir/opam-purifier.lock.json" "$work/edited.json"
  # A lockfile edited by hand, with its lockHash left as it was.
  rewrite_lock "$dir/opam-purifier.lock.json" 'lock["repositories"][0]["archive"] = "https://example.invalid/x.tar.gz"' keep
  expect_failure 'was changed after `opam-purifier lock` wrote it' sh -c "cd '$dir' && '$cli' prefetch"
  expect_failure 'was changed after `opam-purifier lock` wrote it' sh -c "cd '$dir' && '$cli' publish"
  # A malformed lockfile, kept outside the project.
  head -c 200 "$work/edited.json" >"$work/malformed.json"
  cp "$work/edited.json" "$dir/opam-purifier.lock.json"
  expect_failure 'run `opam-purifier lock` to write it again' sh -c "cd '$dir' && '$cli' prefetch --lockfile '$work/malformed.json'"
  # A wrong hash of the repository, re-hashed so that only the fetch can
  # notice. Nix fetches the repository when it evaluates.
  rewrite_lock "$dir/opam-purifier.lock.json" 'lock["repositories"][0]["hash"] = "sha256-" + "A" * 43 + "="' rehash
  expect_failure 'mismatch' build "$dir" packages.hello
  # Opam files edited after the lock.
  cp "$work/edited.json" "$dir/opam-purifier.lock.json"
  echo '# edited' >>"$dir/hello.opam"
  expect_failure 'run `opam-purifier lock`' sh -c "cd '$dir' && '$cli' prefetch"
  # The workspace fixture keeps a download entry, for the URL pin that has
  # no checksum. A wrong hash there fails the build of the download.
  wdir="$(fixture workspace)"
  cp "$wdir/opam-purifier.lock.json" "$work/workspace-edited.json"
  rewrite_lock "$wdir/opam-purifier.lock.json" 'next(d for d in lock["downloads"] if "url" in d)["hash"] = "sha256-" + "A" * 43 + "="' rehash
  expect_failure 'hash mismatch' build "$wdir" packages.beta
  # A lockfile without that entry: opam asks for the URL, and the download
  # command names it and the command to run.
  cp "$work/workspace-edited.json" "$wdir/opam-purifier.lock.json"
  rewrite_lock "$wdir/opam-purifier.lock.json" 'lock["downloads"] = [d for d in lock["downloads"] if "url" not in d]' rehash
  expect_failure 'the lockfile; run `opam-purifier lock`' build "$wdir" packages.beta
}

section_repository() {
  echo "== repository"
  local port project repo
  # A library in a git repository, served over HTTP the way git serves a
  # bare repository without a server program.
  write_package "$work/git/lambda-src" lambda git
  (
    cd "$work/git/lambda-src"
    "$git" init --quiet
    "$git" add -A
    "$git" -c user.name=nix-purifiers -c user.email=nix-purifiers@example.invalid commit --quiet -m "Add lambda"
  )
  "$git" clone --quiet --bare "$work/git/lambda-src" "$work/served-git/lambda.git"
  (cd "$work/served-git/lambda.git" && "$git" update-server-info)
  port="$(serve "$work/served-git")"
  # A repository with one package, whose source is that git repository.
  repo="$work/custom-repository"
  mkdir -p "$repo/packages/lambda/lambda.1"
  echo 'opam-version: "2.0"' >"$repo/repo"
  cat >"$repo/packages/lambda/lambda.1/opam" <<EOF
opam-version: "2.0"
synopsis: "A package with a git source"
maintainer: "nix-purifiers"
depends: [ "ocaml" "dune" ]
build: [ ["dune" "build" "-p" name] ]
url { src: "git+http://127.0.0.1:$port/lambda.git" }
EOF
  project="$work/repository-project"
  write_project "$project" nu '"lambda"' '' 'let () = print_endline Lambda.message'
  (cd "$project" && "$cli" lock --repo "default=https://opam.ocaml.org" --repo "custom=$repo")
  "$python" - "$project/opam-purifier.lock.json" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
assert any(d["path"] == "sources/lambda.1" and "git" in d for d in lock["downloads"]), lock["downloads"]
assert any(p["package"] == "lambda.1" and p.get("repository") for p in lock["pins"]), lock["pins"]
EOF
  [ "$("$(build "$project" packages.nu)/bin/nu")" = "lambda from git" ]
}

section_darcs() {
  echo "== darcs"
  local port project
  make_darcs_package() {
    local repo="$1" name="$2"
    write_package "$repo" "$name" Darcs
    (cd "$repo" && "$darcs" init --quiet && "$darcs" record --quiet --all --look-for-adds --author="$author" -m "Add $name")
  }
  make_darcs_package "$work/darcs/zeta" zeta
  (cd "$work/darcs/zeta" && "$darcs" tag --quiet --author="$author" v1)
  # A patch after the tag, which the tag pin leaves out.
  (cd "$work/darcs/zeta" && echo 'let later = ()' >>zeta.ml && "$darcs" record --quiet --all --author="$author" -m "After v1")
  make_darcs_package "$work/darcs/eta" eta
  port="$(serve "$work/darcs")"
  project="$work/darcs-project"
  write_project "$project" omega '"zeta" "eta"' \
    "[\"zeta.1\" \"darcs+http://127.0.0.1:$port/zeta#v1\"] [\"eta.1\" \"darcs+http://127.0.0.1:$port/eta\"]" \
    'let () = print_endline (Zeta.message ^ ", " ^ Eta.message)'
  (cd "$project" && "$cli" lock)
  "$python" - "$project/opam-purifier.lock.json" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
darcs = {d["path"]: d["darcs"] for d in lock["downloads"] if "darcs" in d}
assert darcs["sources/zeta.1"]["rev"] == "v1" and darcs["sources/zeta.1"]["context"] is None, darcs
assert darcs["sources/eta.1"]["rev"] is None and darcs["sources/eta.1"]["context"], darcs
EOF
  [ "$("$(build "$project" packages.omega)/bin/omega")" = "zeta from Darcs, eta from Darcs" ]
}

section_hg() {
  echo "== hg"
  local port project node
  write_package "$work/hg/theta" theta Mercurial
  (cd "$work/hg/theta" && "$hg" init && "$hg" commit --quiet --addremove --user "$author" -m "Add theta")
  port="$(free_port)"
  "$hg" serve --repository "$work/hg/theta" --address 127.0.0.1 --port "$port" >/dev/null 2>&1 &
  server_pids+=("$!")
  for _ in $(seq 50); do
    "$hg" identify "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
    sleep 0.2
  done
  project="$work/hg-project"
  write_project "$project" kappa '"theta"' "[\"theta.1\" \"hg+http://127.0.0.1:$port/\"]" 'let () = print_endline Theta.message'
  (cd "$project" && "$cli" lock)
  node="$("$hg" log --repository "$work/hg/theta" --rev tip --template '{node}')"
  "$python" - "$project/opam-purifier.lock.json" "$node" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
hg = [d["hg"] for d in lock["downloads"] if "hg" in d]
assert hg and hg[0]["rev"] == sys.argv[2], hg
EOF
  [ "$("$(build "$project" packages.kappa)/bin/kappa")" = "theta from Mercurial" ]
}

sections=("$@")
if [ "${#sections[@]}" -eq 0 ]; then
  sections=(conformance-relock conformance-offline conformance-rebuild conformance-update lockfiles publish negative repository darcs hg)
fi
for section in "${sections[@]}"; do
  "section_$section"
done
echo "== the interactive checks passed: ${sections[*]}"
