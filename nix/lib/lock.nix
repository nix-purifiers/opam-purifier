# SPDX-License-Identifier: MIT
#
# Reads an opam-purifier lockfile (written by `opam-purifier lock`), and
# checks that it is whole, unchanged and made from the opam files in
# `src`. The result is
#
#   problems  why the lockfile cannot be used, each naming the command to
#             run; empty for a usable lockfile
#   lock      the lockfile's content, with the helpers below; read it only
#             when `problems` is empty
#
# opam's own lock files (<package>.opam.locked) are the build tool's
# lockfiles. They are in `src` by default. `opamLocked`, a directory that
# holds them, takes their place when the build is external.
{
  lockFile,
  src,
  opamLocked ? null,
}:
let
  exists = builtins.pathExists lockFile;
  text = builtins.readFile lockFile;
  # A JSON parse error stops evaluation before tryEval can catch it, so
  # the reader first checks that the text is shaped like the JSON object
  # the CLI writes: it starts with `{` and ends with `}` and a newline. A
  # truncated or overwritten lockfile fails here with the command to run.
  length = builtins.stringLength text;
  shaped =
    length > 2 && builtins.substring 0 1 text == "{" && builtins.substring (length - 2) 2 text == "}\n";
  # A parse error cannot become a problem, because Nix cannot catch it, so
  # evaluation fails with the command that fixes the file.
  lock = builtins.addErrorContext "while reading ${toString lockFile}, which is not valid JSON; run `opam-purifier lock` to write it again" (
    builtins.fromJSON text
  );

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

  # The hash the lockfile carries of its own content, the one
  # bin/opam-purifier computes (lock_hash): the SHA-256 of the lockfile
  # without `lockHash`, as compact JSON.
  intact =
    (lock.lockHash or null)
    == "sha256:${builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "lockHash" ]))}";
  # Whether the lockfile was made from the opam files under `src` and the
  # opam lock files: the same manifest bin/opam-purifier hashes
  # (definition_hash), with a line `<path>\t<sha256>` for each definition
  # file and a line for the options. A lockfile written before an edit to
  # an opam file or an opam lock file is stale.
  isCurrent =
    let
      lockedBase = if opamLocked != null then opamLocked else src;
      # The matching files of a directory, as { name, file }: the name the
      # manifest lists, and the path that holds the content.
      inDir =
        base: dir: prefix: matches:
        let
          entries = if builtins.pathExists (base + dir) then builtins.readDir (base + dir) else { };
          names = builtins.filter (n: entries.${n} == "regular" && matches n) (builtins.attrNames entries);
        in
        map (n: {
          name = prefix + n;
          file = base + "${dir}/${n}";
        }) names;
      isOpam = n: n == "opam" || builtins.match ".*\\.opam" n != null;
      isLocked = n: builtins.match ".*\\.opam\\.locked" n != null;
      files = builtins.sort (a: b: a.name < b.name) (
        inDir src "/" "" isOpam ++ inDir src "/opam" "opam/" isOpam ++ inDir lockedBase "/" "" isLocked
      );
      manifest =
        builtins.concatStringsSep "" (map (f: "${f.name}\t${builtins.hashFile "sha256" f.file}\n") files)
        + "options\t${builtins.toJSON lock.options}\n";
    in
    lock.definitionHash == "sha256:${builtins.hashString "sha256" manifest}";

  # Each check runs only when the ones before it pass.
  problems =
    if !exists then
      [
        "opam-purifier: ${toString lockFile} does not exist; run `opam-purifier lock` in the project, and add the lockfile to the repository."
      ]
    else if !shaped then
      [
        "opam-purifier: ${toString lockFile} is not a lockfile that `opam-purifier lock` wrote (it is not a whole JSON object); run `opam-purifier lock` to write it again."
      ]
    else if (lock.version or null) != supportedVersion then
      [
        "opam-purifier: ${toString lockFile} has lock format version ${
          toString (lock.version or "none")
        }; this library reads version ${toString supportedVersion}. Run `opam-purifier lock` with the opam-purifier version that provides this library."
      ]
    else if !intact then
      [
        "opam-purifier: ${toString lockFile} was changed after `opam-purifier lock` wrote it (its lockHash does not match its content); run `opam-purifier lock`."
      ]
    else if !isCurrent then
      [
        "opam-purifier: ${toString lockFile} was made from other opam files than the ones in ${toString src}; run `opam-purifier lock`."
      ]
    else
      [ ];
in
{
  inherit problems;
  lock = lock // {
    inherit storeName downloadName;

    # What a system installs: the locked name.version list and the nixpkgs
    # attributes the depexts name.
    forSystem =
      system:
      lock.systems.${system}
        or (throw "opam-purifier: ${toString lockFile} has no solution for ${system}; the lock covers ${builtins.concatStringsSep ", " (builtins.attrNames lock.systems)}. Run `opam-purifier lock`.");
  };
}
