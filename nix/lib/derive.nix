# SPDX-License-Identifier: MIT
#
# What Nix derives from the opam files of the solved packages, beside
# what the lockfile keeps. A package's opam file in its repository gives
# the URL and checksums of each source. When a checksum is a sha256 or a
# sha512, which Nix can fetch by, the download entry follows from it, so
# bin/opam-purifier leaves that entry out of the lockfile (usable_checksum):
#
#   path     opam's download cache path of the first checksum
#   url      the source URL
#   mirrors  the opam file's mirrors, then opam's cache for each checksum
#   hash     the checksum Nix can fetch by, as an SRI hash
#
# The opam files come from each repository the lockfile records. A
# repository pinned as an archive (`archive`, with the hash of its
# unpacked content) or at a git commit (`git`) is fetched at evaluation,
# with builtins.fetchTarball or builtins.fetchGit, so Nix reads its files
# with no import from a derivation. These fetches use Nix's built-in
# fetchers, never `fetchers`. A repository the lockfile copies (`copied`)
# has its opam files in the lockfile's `repository` entries.
{ lib, lock }:
let
  parse = import ./opam-file.nix { inherit lib; };

  trees = lib.listToAttrs (
    map (
      r:
      lib.nameValuePair r.name (
        if r ? archive then
          builtins.fetchTarball {
            url = r.archive;
            sha256 = r.hash;
          }
        else if r ? git then
          builtins.fetchGit {
            inherit (r.git) url rev;
            shallow = true;
          }
        else
          null
      )
    ) lock.repositories
  );

  nameOf = package: builtins.head (lib.splitString "." package);

  # The packages opam installs from a repository: every solved package but
  # the ones pinned by the project, whose opam files are their own.
  pinnedNames = map (p: p.name) (lib.filter (p: !(p.repository or false)) lock.pins);
  solved = lib.unique (
    lib.concatMap (s: s.install ++ (s.tools or [ ])) (builtins.attrValues lock.systems)
  );
  fromRepositories = lib.filter (p: !(builtins.elem (nameOf p) pinnedNames)) solved;

  defaultRepository = (builtins.head lock.repositories).name;
  originOf = package: (lock.origins or { }).${package} or defaultRepository;
  dirOf = package: "packages/${nameOf package}/${package}";

  inline = lib.listToAttrs (map (e: lib.nameValuePair e.path e.contents) lock.repository);
  opamText =
    package:
    let
      tree = trees.${originOf package};
      path = "${dirOf package}/opam";
    in
    if tree != null then
      builtins.readFile "${tree}/${path}"
    else
      inline.${path}
        or (throw "opam-purifier: the lockfile holds no opam file of ${package}; run `opam-purifier lock`.");

  # The rules of bin/opam-purifier: vcs_of, usable_checksum, cache_path
  # and cache_url.
  isVcs =
    url:
    lib.hasPrefix "git+" url
    || lib.hasPrefix "git://" url
    || lib.hasPrefix "hg+" url
    || lib.hasPrefix "darcs+" url
    || lib.hasSuffix ".git" (builtins.head (lib.splitString "#" url));
  usable = c: builtins.match "sha256=[0-9a-f]{64}|sha512=[0-9a-f]{128}" c != null;
  split =
    checksum:
    let
      parts = lib.splitString "=" checksum;
    in
    {
      kind = builtins.head parts;
      hex = lib.concatStringsSep "=" (builtins.tail parts);
    };
  cachePath =
    checksum:
    let
      c = split checksum;
    in
    "download-cache/${c.kind}/${builtins.substring 0 2 c.hex}/${c.hex}";
  cacheUrl =
    checksum:
    let
      c = split checksum;
    in
    "https://opam.ocaml.org/cache/${c.kind}/${builtins.substring 0 2 c.hex}/${c.hex}";

  entryOf =
    source:
    let
      checksum = lib.findFirst usable null source.checksums;
      c = split checksum;
    in
    if isVcs source.src || checksum == null then
      [ ]
    else
      [
        {
          path = cachePath (builtins.head source.checksums);
          url = source.src;
          mirrors = source.mirrors ++ map cacheUrl source.checksums;
          hash = builtins.convertHash {
            hash = c.hex;
            hashAlgo = c.kind;
            toHashFormat = "sri";
          };
        }
      ];

  # The systems that install a package, or null when every system does.
  systemNames = builtins.attrNames lock.systems;
  systemsOf =
    package:
    let
      names = lib.filter (
        s: builtins.elem package (lock.systems.${s}.install ++ (lock.systems.${s}.tools or [ ]))
      ) systemNames;
    in
    if names == systemNames then null else names;

  derived = lib.concatMap (
    p: map (e: e // { systems = systemsOf p; }) (lib.concatMap entryOf (parse (opamText p)))
  ) fromRepositories;

  # A checkout the lockfile keeps lies at sources/<package>. Its other
  # entries, such as a URL pin of the project, are needed everywhere.
  kept = map (
    d:
    let
      package = lib.removePrefix "sources/" d.path;
    in
    d // { systems = if lib.hasPrefix "sources/" d.path then systemsOf package else null; }
  ) lock.downloads;

  # Two packages can name the same file. The entry is needed wherever
  # either is.
  merge =
    a: b:
    a
    // {
      systems =
        if a.systems == null || b.systems == null then null else lib.unique (a.systems ++ b.systems);
    };
in
{
  inherit trees;

  # The opam file text of each package opam installs from a repository,
  # and the sources the Nix parser reads from it. The tests compare the
  # sources with the ones bin/opam-purifier reads.
  opamTexts = lib.genAttrs fromRepositories opamText;
  sources = lib.genAttrs fromRepositories (p: parse (opamText p));

  # Every download of the build, by path: the derived entries and the ones
  # the lockfile keeps.
  downloads = builtins.attrValues (
    builtins.foldl' (
      acc: d: acc // { ${d.path} = if acc ? ${d.path} then merge acc.${d.path} d else d; }
    ) { } (derived ++ kept)
  );

  # The package directories to copy from the fetched repositories, with
  # their patches and other files.
  repositoryDirs = lib.concatMap (
    p:
    let
      tree = trees.${originOf p};
    in
    lib.optional (tree != null) {
      path = dirOf p;
      source = "${tree}/${dirOf p}";
    }
  ) fromRepositories;
}
