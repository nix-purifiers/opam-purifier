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
  than opam.ocaml.org. The lockfile remembers them for the next lock.
- `--without-test`, to leave the test dependencies out. By default they are
  locked, and the build runs the tests.
- `--with-doc`, to lock the documentation dependencies too.

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
`nix/lib/build-opam-project.nix` documents each one. The builder fails
evaluation when the lockfile was made from other opam files than the ones in
`src`.

The compiler is the one the solution holds. opam usually picks
`ocaml-base-compiler`, and the build compiles it from source, offline, from
the locked archive.

### Interactive mode

```zsh
opam-purifier install
opam-purifier opam exec -- dune build
```

`install` builds the offline state of the lockfile with Nix, keeps it alive
with a GC root under `.opam-purifier/`, and creates the local switch
`_opam` with the locked dependencies, offline. `opam-purifier opam ARGS`
runs opam on that switch with the same offline download command, so opam
refuses any package the lockfile does not hold, with a hint to relock.

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
