# SPDX-License-Identifier: MIT
#
# Reads an opam-purifier lockfile (written by `opam-purifier lock`).
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters. Every other character becomes "_".
  storeName =
    fileName:
    let
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
    in
    builtins.substring 0 200 (if undotted == "" then "file" else undotted);

  # The last part of a download's path names its store path.
  downloadName =
    download:
    let
      parts = builtins.filter builtins.isString (builtins.split "/" download.path);
    in
    storeName (builtins.elemAt parts (builtins.length parts - 1));
in
assert
  lock.version == supportedVersion
  || throw "opam-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `opam-purifier relock` with the opam-purifier version that provides this library.";
lock
// {
  inherit storeName downloadName;

  # The downloads by kind. A file sits at its path in opam's download
  # cache (or under urls/ when its opam file gives no checksum). A
  # checkout sits under sources/.
  files = builtins.filter (d: d ? url) lock.downloads;
  checkouts = builtins.filter (d: !(d ? url)) lock.downloads;

  # Whether the lockfile was made from the opam files under `src`: the
  # same manifest bin/opam-purifier hashes (definition_hash), with a line
  # `<path>\t<sha256>` for each definition file and a line for the
  # options. A lockfile written before an edit to an opam file is stale.
  isCurrentFor =
    src:
    let
      inDir =
        dir: prefix:
        let
          entries = if builtins.pathExists (src + dir) then builtins.readDir (src + dir) else { };
          names = builtins.filter (
            n:
            entries.${n} == "regular"
            && (
              n == "opam"
              || builtins.match ".*\\.opam" n != null
              || (prefix == "" && builtins.match ".*\\.opam\\.locked" n != null)
            )
          ) (builtins.attrNames entries);
        in
        map (n: prefix + n) names;
      files = builtins.sort builtins.lessThan (inDir "/" "" ++ inDir "/opam" "opam/");
      manifest =
        builtins.concatStringsSep "" (
          map (f: "${f}\t${builtins.hashFile "sha256" (src + "/${f}")}\n") files
        )
        + "options\t${builtins.toJSON lock.options}\n";
    in
    lock.definitionHash == "sha256:${builtins.hashString "sha256" manifest}";

  # What a system installs: the locked name.version list and the nixpkgs
  # attributes the depexts name.
  forSystem =
    system:
    lock.systems.${system}
      or (throw "opam-purifier: ${toString lockFile} has no solution for ${system}; the lock covers ${builtins.concatStringsSep ", " (builtins.attrNames lock.systems)}.");
}
