#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# What runs outside the Nix sandbox, on copies of the fixtures. Each
# section is a function; arguments name the sections to run, and the
# default is all of them:
#
#   reproduce    a relock of each fixture, against the pinned repository
#                its lockfile names, writes the committed lockfile byte
#                for byte, and a second `lock` finds it up to date
#   interactive  `install` sets up _opam offline, dune builds, runs and
#                tests the project in it, opam refuses a package the lock
#                does not hold, and a lock with --tool installs the tool
#   lockfiles    with opam's own lock file beside the opam file, the lock
#                run solves with --locked, to the same versions
#   publish      the archive Nix built, served from a local server, goes
#                into a repository checkout and to a stand-in for
#                opam-publish; a different archive at the URL is refused
#   negative     a hand-edited lockfile, a malformed one, a tampered hash,
#                a missing download and stale opam files each fail with a
#                message that names the command to run
#   repository   a custom repository whose package has a git source,
#                served over HTTP, locked with --repo and built
#   darcs        two Darcs repositories made here and served over HTTP,
#                one pinned by tag and one by its head, locked and built
#   hg           a Mercurial repository served by `hg serve`, pinned by
#                its default branch, which the lock resolves to a node
#
# It runs from the repository root and needs nix with flakes and network
# access.
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
author="nix-purifiers <nix-purifiers@example.invalid>"

fixture() {
  rm -rf "$work/$1"
  cp -r "$root/tests/fixtures/$1" "$work/$1"
  chmod -R u+w "$work/$1"
  echo "$work/$1"
}

# Builds an attribute of buildOpamProject for a project directory, with
# the flake's overlay, and prints the store path.
build() {
  local src="$1" attr="$2"
  nix build --no-link --print-out-paths --impure --expr "
    let flake = builtins.getFlake \"$root\";
        pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}.extend flake.overlays.default;
    in (pkgs.buildOpamProject { src = $src; }).$attr"
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

section_reproduce() {
  echo "== reproduce"
  local name dir
  for name in hello workspace; do
    dir="$(fixture "$name")"
    (cd "$dir" && "$cli" relock)
    cmp "$root/tests/fixtures/$name/opam-purifier.lock.json" "$dir/opam-purifier.lock.json"
    (cd "$dir" && "$cli" lock) | grep -q 'is up to date'
  done
}

section_interactive() {
  echo "== interactive"
  local dir
  dir="$(fixture hello)"
  (cd "$dir" && "$cli" install)
  (cd "$dir" && "$cli" opam exec -- dune build)
  [ "$("$dir/_build/default/bin/main.exe")" = "Hello, Nix!" ]
  (cd "$dir" && "$cli" opam exec -- dune test)
  expect_failure 'opam-purifier lock --tool' sh -c "cd '$dir' && '$cli' opam install --yes cmdliner"
  # A tool locked for the interactive mode installs with `install`, and the
  # sandboxed build leaves it out.
  (cd "$dir" && "$cli" lock --tool cmdliner)
  "$python" - "$dir/opam-purifier.lock.json" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
for system in lock["systems"].values():
    assert any(p.startswith("cmdliner.") for p in system["tools"]), system
    assert not any(p.startswith("cmdliner.") for p in system["install"]), system
EOF
  (cd "$dir" && "$cli" install)
  (cd "$dir" && "$cli" opam list --installed --short) | grep -qx cmdliner
}

section_lockfiles() {
  echo "== lockfiles"
  local dir
  dir="$(fixture hello)"
  (cd "$dir" && "$cli" install)
  (cd "$dir" && "$cli" opam lock .)
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
  archive="$(cd "$dir" && "$cli" publish hello | sed -n 's|^opam-purifier: \(/nix/store/.*\.tar\.gz\)$|\1|p')"
  [ -f "$archive" ]
  mkdir -p "$work/served"
  cp --no-preserve=mode "$archive" "$work/served/"
  port="$(serve "$work/served")"
  url="http://127.0.0.1:$port/hello-0.1.0.tar.gz"
  mkdir -p "$work/repository"
  (cd "$dir" && "$cli" publish hello --url "$url" --repository "$work/repository")
  published="$work/repository/packages/hello/hello.0.1.0/opam"
  grep -q "src: \"$url\"" "$published"
  grep -q "sha256=$(sha256sum "$archive" | cut -d' ' -f1)" "$published"
  cat >"$work/opam-publish" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/opam-publish.args"
EOF
  chmod +x "$work/opam-publish"
  (cd "$dir" && OPAM_PURIFIER_OPAM_PUBLISH="$work/opam-publish" "$cli" publish hello --url "$url")
  head -n 1 "$work/opam-publish.args" | grep -qx "$url"
  echo tampered >>"$work/served/hello-0.1.0.tar.gz"
  expect_failure 'serves different bytes' sh -c "cd '$dir' && '$cli' publish hello --url '$url' --repository '$work/repository'"
}

section_negative() {
  echo "== negative"
  local dir
  dir="$(fixture hello)"
  # A lockfile edited by hand, with its lockHash left as it was.
  cp "$dir/opam-purifier.lock.json" "$work/edited.json"
  rewrite_lock "$dir/opam-purifier.lock.json" 'lock["downloads"][0]["url"] = "https://example.invalid/x"' keep
  expect_failure 'was changed after `opam-purifier lock` wrote it' build "$dir" switch.drvPath
  expect_failure 'was changed after `opam-purifier lock` wrote it' sh -c "cd '$dir' && '$cli' install"
  # A malformed lockfile.
  head -c 200 "$work/edited.json" >"$dir/opam-purifier.lock.json"
  expect_failure 'opam-purifier.lock.json' build "$dir" switch.drvPath
  # A tampered hash, re-hashed so that only the fetch can notice.
  cp "$work/edited.json" "$dir/opam-purifier.lock.json"
  rewrite_lock "$dir/opam-purifier.lock.json" 'next(d for d in lock["downloads"] if "url" in d)["hash"] = "sha256-" + "A" * 43 + "="' rehash
  expect_failure 'hash mismatch' build "$dir" switch
  # A download missing from the lockfile: opam asks for it, and the
  # offline download command names the URL and the command to run.
  cp "$work/edited.json" "$dir/opam-purifier.lock.json"
  rewrite_lock "$dir/opam-purifier.lock.json" 'lock["downloads"] = [d for d in lock["downloads"] if "ocaml-base-compiler" not in d.get("url", "") and "ocaml-5" not in d.get("url", "")]' rehash
  expect_failure 'is not in the lockfile; run `opam-purifier lock`' build "$dir" switch
  # Opam files edited after the lock.
  cp "$work/edited.json" "$dir/opam-purifier.lock.json"
  echo '# edited' >>"$dir/hello.opam"
  expect_failure 'run `opam-purifier lock`' build "$dir" switch.drvPath
  expect_failure 'run `opam-purifier lock`' sh -c "cd '$dir' && '$cli' install"
  expect_failure 'run `opam-purifier lock`' sh -c "cd '$dir' && '$cli' opam list"
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
  sections=(reproduce interactive lockfiles publish negative repository darcs hg)
fi
for section in "${sections[@]}"; do
  "section_$section"
done
echo "== the interactive checks passed: ${sections[*]}"
