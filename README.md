# opam-purifier

opam-purifier is a command and a Nix library for [opam](https://opam.ocaml.org)
projects. It records the files opam wants to download in a lockfile, so that
Nix can build the project in its sandbox. You do not commit any generated Nix
files to your repository.

## How it works

`opam-purifier lock` runs opam in an empty opam root, against the
repositories you name. The default is opam.ocaml.org. For each Nix system
(x86_64-linux and aarch64-linux), it lets opam solve the project's
dependencies with that system's platform variables, and downloads what the
solution needs. The lockfile `opam-purifier.lock.json` then holds:

- the packages each system installs, by exact version, and the NixOS system
  packages ("depexts") they need, which opam's metadata names as nixpkgs
  attributes;
- the opam file of every solved package, so that the build needs no copy of
  the repository;
- every archive, as a URL with SHA-256, fallback mirrors and the path in
  opam's download cache;
- every pinned or version-control source, as a git, Mercurial or Darcs
  checkout at a fixed revision;
- the files each of the project's packages installs. The lock run builds the
  project in the Nix sandbox from the lockfile it has written, with the tests
  running, and records what opam installed.

If the project has opam lock files (`*.opam.locked`), the lock run solves
with `--locked`, so opam's own versions decide.

The build sets up an opam root with a repository made of the locked opam
files, a download cache made of the locked archives, and a download command
that serves only locked files. opam then installs the locked packages and
the project, offline.

## Use

In the project root, where the opam files are:

```zsh
nix run github:nix-purifiers/opam-purifier -- lock
```

Commit `opam-purifier.lock.json`. `lock` does nothing while the opam files,
opam lock files and lock options are unchanged; `relock` locks again
anyway. The options are:

- `--repo NAME=URL`, once per repository, to resolve from repositories other
  than opam.ocaml.org. `archive+URL` names an archive of a repository, such
  as opam-repository at a commit:
  `--repo default=archive+https://github.com/ocaml/opam-repository/archive/<commit>.tar.gz`.
  opam.ocaml.org changes every day, so a relock against it may pick newer
  versions; against an archive of a commit, a relock writes the same lockfile
  byte for byte.
- `--only PACKAGE`, once per package, to lock some of the project's packages
  and leave the others out, such as a benchmark package with heavy
  dependencies. The default is every package with an opam file.
- `--tool PACKAGE`, once per package, to lock a tool for the interactive mode
  only, such as `ocaml-lsp-server` or `ocamlformat`. opam solves the tools
  together with the project, so they agree on shared versions, and the Nix
  build leaves them out.
- `--without-test`, to leave the test dependencies out. By default they are
  locked, and the build runs the tests.
- `--with-doc`, to lock the documentation dependencies too.

The lockfile remembers the options for the next `lock` and `relock`.

The flake's `overlays.default` adds `buildOpamProject` to a package set:

```nix
{ buildOpamProject }:
(buildOpamProject { src = ./.; }).packages.hello
```

The builder returns:

| Attribute | What it is |
|---|---|
| `packages.<name>` | the files the project's package `<name>` installs; `files."<path>"` names each one, and `executables.<name>` each one under `bin/` |
| `switch` | an opam switch at `_opam`, with the locked dependencies and the project's packages installed |
| `releases.<name>` | the reproducible source archive `<name>-<version>.tar.gz` for publishing |
| `state` | the offline repository, download cache and sources the build installs from |

Nix knows every name in the table when it evaluates, from the lockfile.
Its arguments are `src`, `lockFile`, `doCheck`, `nativeBuildInputs`,
`buildInputs` (for libraries the depexts do not name), `srcFilter`, and
`fetchurl` and `fetchgit` (for credentials or mirrors).
`nix/lib/build-opam-project.nix` documents each one.

The builder fails evaluation, with the command to run, when the lockfile was
made from other opam files than the ones in `src`, when the lockfile was
changed after `opam-purifier lock` wrote it (it carries a hash of its own
content), or when it is not a lockfile. A download that does not match its
locked hash fails the build, and so does a file opam asks for that the
lockfile does not hold, with the URL and the command to run.

The compiler is the one the solution holds. opam usually picks
`ocaml-base-compiler`, and the build compiles it from source, offline, from
the locked archive.

### Interactive mode

```zsh
opam-purifier install
opam-purifier opam exec -- dune build
opam-purifier opam exec -- dune test
```

For an editor, lock the language server as a tool:

```zsh
opam-purifier lock --tool ocaml-lsp-server
opam-purifier install
```

The server is then `_opam/bin/ocamllsp`. The switch belongs to the
purifier's opam root (`.opam-purifier/root`), not to your own, so configure
the editor to start `opam-purifier opam exec -- ocamllsp` as its language
server command, or `_opam/bin/ocamllsp` with `OPAM_SWITCH_PREFIX` set to
`_opam`. To add or upgrade a dependency, edit the opam file, then run
`opam-purifier lock` and `opam-purifier install`.

`install` builds the offline state of the lockfile with Nix, keeps it alive
with a GC root under `.opam-purifier/`, and creates the local switch
`_opam` with the locked dependencies, offline. `opam-purifier opam ARGS`
runs opam on that switch with the same offline download command, so opam
refuses any package the lockfile does not hold, with a hint to relock.
Both run inside a Nix shell with the tools of the sandboxed build (a C
toolchain, make, opam's helpers) and the system packages the depexts name,
so the local switch builds the way the Nix build does.

### Publishing

```zsh
opam-purifier publish hello
opam-purifier publish hello --url https://example.org/hello-0.1.0.tar.gz --repository ~/opam-repository
```

`publish` builds the package's release archive with Nix and prints its
checksums. Upload the archive. With `--url`, it checks that the URL serves
the same bytes, adds a `url` section with the checksums to the package's
opam file, and writes it into a checkout of the target repository
(`--repository`), for a pull request. Without `--repository`, it hands the
URL and the opam file to `opam-publish`.

## Sources

| Source | How the lock keeps it |
|---|---|
| a repository archive with checksums | a file entry at its opam download cache path, with opam.ocaml.org's cache as a mirror |
| an archive without checksums, such as a `pin-depends` URL | a file entry, served to opam by URL |
| `git+https://…`, `git+ssh://…` | a git entry with submodules, at the commit of the ref; SSH URLs are fetched over HTTPS from the same host |
| `hg+https://…` | a Mercurial entry |
| `darcs+https://…` | a Darcs entry, by tag when the URL names one, otherwise by the context file of the head the lock run saw |
| a `pin-depends` path inside the project | the project's own directory |

A `pin-depends` path outside the project stops the lock run, since the
sandbox cannot see it. Move the package into the project or pin it by URL.

## Tests

`nix flake check` builds the CLI, whose install check runs the unit tests of
the opam file parser, the source URLs, the download cache paths and the
lockfile hashes (`tests/test_opam_purifier.py`). It builds the fixtures under
`tests/fixtures` from their committed lockfiles in the sandbox: `hello` (an
executable, a library and a test, on repository archives) and `workspace`
(two local packages, a git pin and a URL pin without a checksum). It also
runs what they build, checks the recorded outputs and the release archive,
and checks that a stale lockfile fails evaluation.

`tests/interactive.sh` runs what needs the network or runs outside the
sandbox: a relock of each fixture against its pinned repository archive,
compared byte for byte with the committed lockfile; the interactive mode with
dune and a `--tool`; opam lock files; `publish`; the failures for an edited,
malformed or tampered lockfile, a missing download and stale opam files; and
a custom repository with a git source, Darcs pins by tag and by context, and
a Mercurial pin, each from repositories the script makes and serves itself.
CI runs both on x86_64-linux and aarch64-linux.

## Limits

- **Two systems.** The lock covers x86_64-linux and aarch64-linux. opam
  supports other platforms, but the Nix library builds only these.
- **Installed files come from x86_64 or aarch64, whichever ran the lock.**
  The lock run records the outputs from its own system's build. A package
  that installs different files on the other system fails that system's
  build with a message to relock there.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). The design follows
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier).

## License

MIT
