# opam-purifier

opam-purifier is a command and a Nix library for [opam](https://opam.ocaml.org)
projects. The command records what a project downloads in a lockfile, and
the library builds the project in the Nix sandbox from it. You do not
commit any generated Nix files to your repository. opam-purifier meets the
[purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md)
that every nix-purifier meets.

## 1. Quickstart

In the project root, where the opam files are, lock the project and commit
the lockfile:

```zsh
nix run github:nix-purifiers/opam-purifier -- lock
git add opam-purifier.lock.json
```

`lock` runs opam in an empty opam root for each Nix system (x86_64-linux
and aarch64-linux), solves the project's dependencies with that system's
platform variables, and records the result. It then builds the project in
the Nix sandbox, with its tests, to record the files each package installs.

The flake's `overlays.default` adds the builder `buildOpamProject` to the
package set, where nixpkgs keeps its own builders. Build the project from a
flake:

```nix
{
  inputs.opam-purifier.url = "github:nix-purifiers/opam-purifier";
  inputs.nixpkgs.follows = "opam-purifier/nixpkgs";

  outputs =
    { nixpkgs, opam-purifier, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux.extend opam-purifier.overlays.default;
      project = pkgs.buildOpamProject { src = ./.; };
    in
    {
      packages.x86_64-linux.default = project.packages.hello;
      checks.x86_64-linux.tests = project.tests;
    };
}
```

A package in your own overlay takes the builder by name, like any other
builder, and `buildOpamProject.override` replaces what the builder takes
from the package set:

```nix
# hello.nix
{ buildOpamProject }: (buildOpamProject { src = ./.; }).packages.hello
```

The builder takes `src`, `lockFile` (the default is
`opam-purifier.lock.json` in `src`), `fetchers`, `name`, `releasePackage`,
`nativeBuildInputs`, `buildInputs` (for libraries that the depexts of the
locked packages do not name) and `srcFilter`. `nix/lib/project.nix`
documents each one. It returns:

| Attribute | What it is |
|---|---|
| `packages.<name>` | the files the project's package `<name>` installs; `files."<path>"` names each one, and `executables.<name>` each one under `bin/` |
| `tests` | the project built with its tests, which opam runs as it installs each package |
| `release` | the reproducible source archive `<name>-<version>.tar.gz` that `publish` uploads |
| `fetches` | the entries of the `purifier` library that the build fetches, for SBOM, license and vulnerability tools |

Nix knows every name in the table when it evaluates, from the lockfile.
`lib.opam-purifier.readLock { src, lockFile }` gives the lock in memory of
the contract: `{ purifier, entries, outputs, problems }`.

The compiler is the one the solution holds. opam usually picks
`ocaml-base-compiler`, and the build compiles it from source, offline, from
the locked archive.

## 2. Development loop

```zsh
opam-purifier prefetch
source .opam-purifier/env.sh
dune build
dune test
```

`prefetch` sets up the local switch `_opam` with the locked dependencies,
and writes `.opam-purifier/env.sh`. Sourcing it puts the build tools, the
system libraries the depexts name, and the switch on `PATH`. Put the same
line in an `.envrc` for direnv. From there `dune`, `opam` and your editor
work as they do in any opam project.

The `opam` in that environment runs on a root that holds only the locked
packages, with a download command that serves only locked files. An
`opam install` of anything else fails with a message that names
`opam-purifier lock`.

To add a dependency, add it to the opam file, then run:

```zsh
opam-purifier lock
opam-purifier prefetch
```

`lock` solves again, and `update` re-resolves:

```zsh
opam-purifier update
opam-purifier update fmt cmdliner
```

`lock` keeps the commits of the git repositories that the lockfile records,
so a relock of an unchanged project writes the lockfile byte for byte.
`update` moves each git repository to the commit its ref names now, for all
packages or the ones named, and the packages it leaves alone stay at their
locked versions. When the project has opam lock files (`*.opam.locked`),
`lock` solves with `--locked` so that opam decides the versions, and
`update` writes the lock files again from the build.

`lock` takes these options, and remembers them for the next run:

- `--repo NAME=URL`, once per repository, to resolve from repositories other
  than the default, which is opam-repository on GitHub. `archive+URL` names
  an archive of a repository, such as opam-repository at a commit:
  `--repo default=archive+https://github.com/ocaml/opam-repository/archive/<commit>.tar.gz`.
  `git+URL#REF` names a git repository.
- `--only PACKAGE`, once per package, to lock some of the project's packages
  and leave the others out, such as a benchmark package with heavy
  dependencies. The default is every package with an opam file.
- `--tool PACKAGE`, once per package, to lock a tool for the development loop
  only; see the Editor section.
- `--without-test` and `--with-test` choose whether the test dependencies
  are locked, which they are by default. `--with-doc` and `--without-doc`
  do the same for the documentation dependencies.

The lockfile can live outside the project. Every command takes
`--lockfile PATH`, or reads the environment variable
`OPAM_PURIFIER_LOCKFILE`, and the builder takes the same path as
`lockFile`. A packaging flake can build a project whose author does not
change it, with the lockfile kept in the packaging flake. Its dev shell can
set the variable to the path it passes as `lockFile`. `prefetch` then keeps
`.opam-purifier`, with the garbage-collector roots and `env.sh`, beside the
lockfile.

### Publishing

```zsh
opam-purifier publish
opam-purifier publish --url https://example.org/hello-0.1.0.tar.gz --repository ~/opam-repository
```

`publish` builds the `release` archive with Nix and prints its checksums.
Upload the archive. With `--url`, it checks that the URL serves the same
bytes, adds a `url` section with the checksums to the opam file of each
package of the project, and writes them into a checkout of the target
repository (`--repository`), for a pull request. Without `--repository`, it
hands the URL and the opam files to `opam-publish`.

## 3. Working offline

After `prefetch`, the development loop works with the network cut off.
`prefetch` puts the following in the Nix store, and keeps it there with
garbage-collector roots under `.opam-purifier`, beside the lockfile:

- the repository the locked packages come from, and every locked download:
  archives, git, Mercurial and Darcs checkouts, and the sources of pins;
- the tools the lockfile holds (`--tool`);
- the environment of the sandboxed build: the C toolchain, `make`, `opam`
  and what it runs to unpack sources, and the system packages the depexts
  name.

Anything the lockfile does not hold stays unavailable offline. A command
that needs it stops with a message that names `opam-purifier lock`.

## 4. Editor

Lock the language server and the formatter as tools:

```zsh
opam-purifier lock --tool ocaml-lsp-server --tool ocamlformat
opam-purifier prefetch
```

opam solves the tools together with the project, so they agree on shared
versions, and the Nix build leaves them out. `prefetch` installs them into
`_opam`, and `source .opam-purifier/env.sh` puts `ocamllsp` and
`ocamlformat` on `PATH`. Start the editor from that environment, or from
direnv. The server runs offline.

## 5. Troubleshooting

The commands and the Nix library fail with a message that names the fix.

| What happened | What the message says |
|---|---|
| The opam files changed after the lock | `was made from other opam files than the ones in <src>; run `opam-purifier lock``. |
| The lockfile was edited by hand | `was changed after `opam-purifier lock` wrote it (its lockHash does not match its content); run `opam-purifier lock``. |
| The lockfile is cut off or overwritten | `is not a lockfile that `opam-purifier lock` wrote (it is not a whole JSON object); run `opam-purifier lock` to write it again`. |
| The lockfile does not exist | `does not exist; run `opam-purifier lock` in the project, and add the lockfile to the repository`. |
| The lockfile has another format version | `has lock format version N; this library reads version M`. Run `opam-purifier lock` with the matching version. |
| opam asks for a file the lockfile does not hold | `<url> is not in the lockfile; run `opam-purifier lock``. |
| `opam install` of an unlocked package in the development loop | `opam installs only what the lockfile holds`, with the steps to add a dependency or a tool. |
| A download does not match its locked hash | the build fails with Nix's hash mismatch error. |
| A package installs other files on the other system | the build fails and names the missing file; run `opam-purifier lock` on that system. |

## 6. Supported language repositories

| Source | How the lock keeps it |
|---|---|
| a repository archive with a sha256 or sha512 checksum | nothing: Nix derives the download from the package's opam file, at opam's download cache path, with opam's cache as a mirror |
| an archive without such a checksum, such as an md5-only source or a `pin-depends` URL | a file entry, with the SHA-256 the lock run computed |
| `git+https://…`, `git+ssh://…` | a git entry with submodules, at the commit of the ref; SSH URLs are fetched over HTTPS from the same host |
| `hg+https://…` | a Mercurial entry, at the node the ref names |
| `darcs+https://…` | a Darcs entry, by tag when the URL names one, otherwise by the context file of the head the lock run saw |
| a `pin-depends` path inside the project | the project's own directory |
| a repository as `archive+URL` or `git+URL#REF` | its URL and hash, or its commit; Nix fetches it at evaluation and reads the opam files from it |
| any other repository | a copy of the opam files of the packages solved from it |

Not supported:

- A `pin-depends` path outside the project. The sandbox cannot see it, so
  the lock run stops. Move the package into the project or pin it by URL.
- Subversion, Bazaar, Fossil, Pijul and CVS sources of opam packages. The
  lock run reads git, Mercurial and Darcs sources.

Limits:

- **Two systems.** The lock covers x86_64-linux and aarch64-linux. opam
  supports other platforms, but the Nix library builds only these.
- **Installed files come from the system that ran the lock.** The lock run
  records the outputs from the build on its own system. A package that
  installs different files on the other system fails the build there, with
  a message to lock on that system.
- **The repository fetch is Nix's own.** The repository named as `archive`
  or `git` is fetched at evaluation with `builtins.fetchTarball` or
  `builtins.fetchGit`, so that Nix can read the opam files with no
  import-from-derivation. That fetch does not go through `fetchers`, and it
  needs network access, or a store that already holds the repository, at
  evaluation. A repository kept as copied files has no such fetch.

## 7. Examples

### ocaml-uri

[ocaml-uri](https://github.com/mirage/ocaml-uri) is a library for parsing
URIs. It is not your project, so the lockfile lives in a flake of your own
that packages it. Lock it from a checkout, and write the lockfile beside
the flake:

```zsh
git clone --branch v4.4.0 https://github.com/mirage/ocaml-uri
cd ocaml-uri
nix run github:nix-purifiers/opam-purifier -- lock \
  --only uri --only uri-re --only uri-sexp \
  --lockfile ../uri.lock.json
```

The repository also holds a benchmark package, `uri-bench`. `--only` locks
the three library packages and leaves it out.

The flake takes the source from GitHub and the lockfile from beside it:

```nix
{
  inputs.opam-purifier.url = "github:nix-purifiers/opam-purifier";
  inputs.nixpkgs.follows = "opam-purifier/nixpkgs";
  inputs.uri = {
    url = "github:mirage/ocaml-uri/v4.4.0";
    flake = false;
  };

  outputs =
    { nixpkgs, opam-purifier, uri, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux.extend opam-purifier.overlays.default;
      project = pkgs.buildOpamProject {
        src = uri;
        lockFile = ./uri.lock.json;
      };
    in
    {
      packages.x86_64-linux = {
        inherit (project.packages) uri uri-re uri-sexp;
      };
      checks.x86_64-linux.tests = project.tests;
    };
}
```

`nix build .#uri` builds the library, and `nix flake check` builds all
three packages with their tests. To change the version, change the tag in
the flake and in the `git clone`, and run the `lock` command again.

For a project of your own, run the Quickstart in its checkout instead, and
leave out `--lockfile` so that the lockfile sits next to the opam files.

## 8. Credits

The purifier idea was inspired by the cargo (libnix) project of nixcloud:
[nixcloud/cargo](https://github.com/nixcloud/cargo). The design follows
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier), and the
download entries and the lock in memory come from the shared
[purifier](https://github.com/nix-purifiers/purifier) library.

## License

MIT
