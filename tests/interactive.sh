#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# What runs outside the Nix sandbox, on copies of the fixtures:
#
#   - the lock run (`opam-purifier relock`) of each fixture, and a second
#     `lock` that finds the lockfile up to date
#   - the interactive mode: `install` sets up _opam offline, dune builds
#     and runs the project in it, and opam refuses a package the lock does
#     not hold
#   - `publish`: the archive Nix built, served from a local server, goes
#     into a repository checkout and to a stand-in for opam-publish
#   - Darcs sources: two Darcs repositories made here and served over
#     HTTP, one pinned by tag and one by its head, locked and built
#   - a Mercurial source: a repository made here and served by `hg
#     serve`, pinned by its default branch, which the lock resolves to a
#     node
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

fixture() {
  cp -r "$root/tests/fixtures/$1" "$work/$1"
  chmod -R u+w "$work/$1"
  echo "$work/$1"
}

# Serves a directory over HTTP on a free local port and prints the port.
serve() {
  local dir="$1" port
  port="$("$python" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
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

echo "== the lock run"
for name in hello workspace; do
  dir="$(fixture "$name")"
  (cd "$dir" && "$cli" relock)
  (cd "$dir" && "$cli" lock) | grep -q 'is up to date'
  "$python" - "$dir/opam-purifier.lock.json" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
assert set(lock["systems"]) == {"x86_64-linux", "aarch64-linux"}, lock["systems"].keys()
for package in lock["packages"]:
    assert package["files"], f"{package['name']} records no outputs"
assert all("mirrors" in d for d in lock["downloads"] if "url" in d)
EOF
done

echo "== the interactive mode"
dir="$work/hello"
(cd "$dir" && "$cli" install)
(cd "$dir" && "$cli" opam exec -- dune build)
[ "$("$dir/_build/default/bin/main.exe")" = "Hello, Nix!" ]
(cd "$dir" && "$cli" opam exec -- dune test)
if (cd "$dir" && "$cli" opam install --yes cmdliner) 2>"$work/refused.log"; then
  echo "opam installed a package the lock does not hold" >&2
  exit 1
fi

echo "== opam lock files"
# opam's own lock file pins the versions installed in _opam. With it
# beside the opam file, the lock run solves with --locked, to the same
# versions.
(cd "$dir" && "$cli" opam lock .)
[ -f "$dir/hello.opam.locked" ]
(cd "$dir" && "$cli" lock)
"$python" - "$dir/opam-purifier.lock.json" "$dir/hello.opam.locked" <<'EOF'
import json, re, sys
lock = json.load(open(sys.argv[1]))
assert lock["options"]["locked"], lock["options"]
locked = dict(re.findall(r'"([^"]+)" \{= "([^"]+)"', open(sys.argv[2]).read()))
installs = dict(p.split(".", 1) for p in lock["systems"]["x86_64-linux"]["install"])
for name, version in locked.items():
    if name in installs:
        assert installs[name] == version, (name, installs[name], version)
EOF

echo "== publish"
# Without --url, publish builds the archive and prints its path.
archive="$(cd "$dir" && "$cli" publish hello | sed -n 's|^opam-purifier: \(/nix/store/.*\.tar\.gz\)$|\1|p')"
[ -f "$archive" ]
mkdir -p "$work/served"
cp "$archive" "$work/served/"
port="$(serve "$work/served")"
url="http://127.0.0.1:$port/hello-0.1.0.tar.gz"
mkdir -p "$work/repository"
(cd "$dir" && "$cli" publish hello --url "$url" --repository "$work/repository")
published="$work/repository/packages/hello/hello.0.1.0/opam"
grep -q "src: \"$url\"" "$published"
grep -q "sha256=$(sha256sum "$archive" | cut -d' ' -f1)" "$published"
cat > "$work/opam-publish" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/opam-publish.args"
EOF
chmod +x "$work/opam-publish"
(cd "$dir" && OPAM_PURIFIER_OPAM_PUBLISH="$work/opam-publish" "$cli" publish hello --url "$url")
head -n 1 "$work/opam-publish.args" | grep -qx "$url"
echo tampered >> "$work/served/hello-0.1.0.tar.gz"
if (cd "$dir" && "$cli" publish hello --url "$url" --repository "$work/repository") 2>/dev/null; then
  echo "publish accepted an archive that differs from the one Nix built" >&2
  exit 1
fi

echo "== Darcs sources"
# Writes a small dune library package with its opam file into a directory.
write_package() {
  local dir="$1" name="$2" origin="$3"
  mkdir -p "$dir"
  cat > "$dir/dune-project" <<'EOF'
(lang dune 3.0)
EOF
  cat > "$dir/$name.opam" <<EOF
opam-version: "2.0"
name: "$name"
version: "1"
synopsis: "A $origin fixture for opam-purifier"
maintainer: "nix-purifiers"
depends: [ "ocaml" "dune" ]
build: [ ["dune" "build" "-p" name] ]
EOF
  cat > "$dir/dune" <<EOF
(library (name $name) (public_name $name))
EOF
  echo "let message = \"$name from $origin\"" > "$dir/$name.ml"
}

make_darcs_package() {
  local repo="$1" name="$2"
  write_package "$repo" "$name" Darcs
  (
    cd "$repo"
    "$darcs" init --quiet
    "$darcs" record --quiet --all --look-for-adds --author="nix-purifiers <nix-purifiers@example.invalid>" -m "Add $name"
  )
}
make_darcs_package "$work/darcs/zeta" zeta
(cd "$work/darcs/zeta" && "$darcs" tag --quiet --author="nix-purifiers <nix-purifiers@example.invalid>" v1)
# A patch after the tag, which the tag pin leaves out.
(cd "$work/darcs/zeta" && echo 'let later = ()' >> zeta.ml && "$darcs" record --quiet --all --author="nix-purifiers <nix-purifiers@example.invalid>" -m "After v1")
make_darcs_package "$work/darcs/eta" eta
port="$(serve "$work/darcs")"
project="$work/darcs-project"
mkdir -p "$project/bin"
cat > "$project/dune-project" <<'EOF'
(lang dune 3.0)
EOF
cat > "$project/omega.opam" <<EOF
opam-version: "2.0"
name: "omega"
version: "1"
synopsis: "A project on two Darcs pins"
maintainer: "nix-purifiers"
depends: [ "ocaml" "dune" "zeta" "eta" ]
pin-depends: [
  ["zeta.1" "darcs+http://127.0.0.1:$port/zeta#v1"]
  ["eta.1" "darcs+http://127.0.0.1:$port/eta"]
]
build: [ ["dune" "build" "-p" name] ]
EOF
cat > "$project/bin/dune" <<'EOF'
(executable (name omega) (public_name omega) (libraries zeta eta))
EOF
echo 'let () = print_endline (Zeta.message ^ ", " ^ Eta.message)' > "$project/bin/omega.ml"
(cd "$project" && "$cli" lock)
"$python" - "$project/opam-purifier.lock.json" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
darcs = {d["path"]: d["darcs"] for d in lock["downloads"] if "darcs" in d}
assert darcs["sources/zeta.1"]["rev"] == "v1" and darcs["sources/zeta.1"]["context"] is None, darcs
assert darcs["sources/eta.1"]["rev"] is None and darcs["sources/eta.1"]["context"], darcs
EOF
omega="$(nix build --no-link --print-out-paths --impure --expr "
  let pkgs = (builtins.getFlake \"$root\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}.extend (builtins.getFlake \"$root\").overlays.default;
  in (pkgs.buildOpamProject { src = $project; }).packages.omega")"
[ "$("$omega/bin/omega")" = "zeta from Darcs, eta from Darcs" ]

echo "== a Mercurial source"
write_package "$work/hg/theta" theta Mercurial
(
  cd "$work/hg/theta"
  "$hg" init
  "$hg" commit --quiet --addremove --user "nix-purifiers <nix-purifiers@example.invalid>" -m "Add theta"
)
hg_port="$("$python" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
"$hg" serve --repository "$work/hg/theta" --address 127.0.0.1 --port "$hg_port" >/dev/null 2>&1 &
server_pids+=("$!")
for _ in $(seq 50); do
  "$hg" identify "http://127.0.0.1:$hg_port/" >/dev/null 2>&1 && break
  sleep 0.2
done
project="$work/hg-project"
mkdir -p "$project/bin"
cat > "$project/dune-project" <<'EOF'
(lang dune 3.0)
EOF
cat > "$project/kappa.opam" <<EOF
opam-version: "2.0"
name: "kappa"
version: "1"
synopsis: "A project on a Mercurial pin"
maintainer: "nix-purifiers"
depends: [ "ocaml" "dune" "theta" ]
pin-depends: [ ["theta.1" "hg+http://127.0.0.1:$hg_port/"] ]
build: [ ["dune" "build" "-p" name] ]
EOF
cat > "$project/bin/dune" <<'EOF'
(executable (name kappa) (public_name kappa) (libraries theta))
EOF
echo 'let () = print_endline Theta.message' > "$project/bin/kappa.ml"
(cd "$project" && "$cli" lock)
node="$("$hg" log --repository "$work/hg/theta" --rev tip --template '{node}')"
"$python" - "$project/opam-purifier.lock.json" "$node" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
hg = [d["hg"] for d in lock["downloads"] if "hg" in d]
assert hg and hg[0]["rev"] == sys.argv[2], hg
EOF
kappa="$(nix build --no-link --print-out-paths --impure --expr "
  let pkgs = (builtins.getFlake \"$root\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}.extend (builtins.getFlake \"$root\").overlays.default;
  in (pkgs.buildOpamProject { src = $project; }).packages.kappa")"
[ "$("$kappa/bin/kappa")" = "theta from Mercurial" ]

echo "== all interactive checks passed"
