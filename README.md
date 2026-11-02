# opam-purifier

opam-purifier keeps opam's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/opam-purifier'
opam-purifier lock
opam-purifier prefetch
source .opam-purifier/env.sh
dune build
dune test
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

For persistent use, add these packages through your usual Nix configuration.


## Development loop

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
locked versions.

opam's own lock files (`*.opam.locked`) record package versions and no
download URLs or hashes, so `opam-purifier.lock.json` records the rest. When
the project has opam lock files, `lock` solves with `--locked` so that
opam decides the versions, and `update` writes the lock files again from
the build. `lock` does not create an opam lock file that is missing. A
project without one gets its versions from the solution that `lock`
records in `opam-purifier.lock.json`.

opam runs plugins as `opam-<name>` executables. opam-purifier is a
standalone command instead, because `lock` runs opam in an empty opam root
of its own, apart from the one you work in.

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

A build can keep both lockfiles outside the project. This suits a flake
that packages a project whose author does not change it, and a project
whose committed lockfiles are missing or stale. Every command takes
`--lockfile PATH` for `opam-purifier.lock.json`, or reads the environment
variable `OPAM_PURIFIER_LOCKFILE`, and the builder takes the same path as
`lockFile`. For opam's lock files, every command takes
`--tool-lockfile DIR`, or reads `OPAM_PURIFIER_TOOL_LOCKFILE`, and the
builder takes the directory as `opamLocked`. With `--tool-lockfile`, `lock`
and `update` write `*.opam.locked` into that directory and leave the copies
in the project as they are, and `lock` starts from the copies in the
project when the directory does not hold them yet. The dev shell of the
packaging flake can set both variables to the paths it passes to the
builder, so a developer in that shell runs the commands with no flag.
`prefetch` keeps `.opam-purifier`, with the garbage-collector roots and
`env.sh`, beside the lockfile.

### Publishing

```zsh
opam-purifier publish
opam-purifier publish --url \
  https://example.org/hello-0.1.0.tar.gz --repository \
  ~/opam-repository
```

`publish` builds the `release` archive with Nix and prints its checksums.
Upload the archive. With `--url`, it checks that the URL serves the same
bytes, adds a `url` section with the checksums to the opam file of each
package of the project, and writes them into a checkout of the target
repository (`--repository`), for a pull request. Without `--repository`, it
hands the URL and the opam files to `opam-publish`.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

`result` links to the files that the project's package `hello` installs.
Use `.tests` in place of `.packages.hello` to build the project with its
tests.

### A flake that packages the project

A project whose authors want a flake can have one, in its repository or in
another one. The flake calls the builder directly:

```nix
{
  inputs.opam-purifier.url = "github:nix-purifiers/opam-purifier";
  inputs.nixpkgs.follows = "opam-purifier/nixpkgs";

  outputs =
    { nixpkgs, opam-purifier, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux.extend opam-purifier.overlays.default;
      project = pkgs.opam-purifier.buildOpamProject { src = ./.; };
    in
    {
      packages.x86_64-linux.default = project.packages.hello;
      checks.x86_64-linux.tests = project.tests;
    };
}
```

`overlays.default` adds one attribute to the package set, the scope
`opam-purifier`. It holds the builder `buildOpamProject` and the command
`opam-purifier`. `opam-purifier.overrideScope` replaces what the scope
shares, and `opam-purifier.buildOpamProject.override` replaces what the
builder takes from the package set.

The builder takes `src`, `lockFile` (the default is
`opam-purifier.lock.json` in `src`), `opamLocked` (a directory that holds
opam's lock files, in place of the ones in `src`), `fetchers`, `name`,
`releasePackage`, `nativeBuildInputs`, `buildInputs` (for libraries that
the depexts of the locked packages do not name) and `srcFilter`.
`nix/lib/project.nix` documents each one.

The builder as a package takes the whole package set, `pkgs`, beside the
packages it needs by name. The lockfile names the system dependencies of
the locked packages, the depexts, by nixpkgs attribute, and the builder
looks each one up in the package set by that name. The builder returns:

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

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/opam-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.opam-purifier.buildOpamProject { src = ./.; })
.packages.hello'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

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

## Editor

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

## Troubleshooting

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

## Supported language repositories

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

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### ocaml-uri

[ocaml-uri](https://github.com/mirage/ocaml-uri) is a library for parsing
URIs. In your checkout of it, lock the three library packages, commit the
lockfile with the project, and build the library from the checkout:

```zsh
git clone --branch v4.4.0 https://github.com/mirage/ocaml-uri
cd ocaml-uri
nix run github:nix-purifiers/opam-purifier -- lock \
  --only uri --only uri-re --only uri-sexp
git add opam-purifier.lock.json
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/opam-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.opam-purifier.buildOpamProject { src = ./.; })
.packages.uri'
```

The repository also holds a benchmark package, `uri-bench`. `--only` locks
the three library packages and leaves it out. Use `.tests` in place of
`.packages.uri` to build all three with their tests. To change the
version, check out another tag and run the `lock` command again.

### ocaml-uri with the lockfile outside the repository

To leave the repository as it is, write the lockfile beside the checkout and
point the build at it:

```zsh
nix run github:nix-purifiers/opam-purifier -- lock \
  --only uri --only uri-re --only uri-sexp \
  --lockfile ../uri.lock.json
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/opam-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.opam-purifier.buildOpamProject {
  src = ./.;
  lockFile = ../uri.lock.json;
}).packages.uri'
```

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
