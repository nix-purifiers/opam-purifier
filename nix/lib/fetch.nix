# SPDX-License-Identifier: MIT
#
# The fetcher for locked downloads. The lock holds the download shapes of
# the shared nix-purifiers library:
#
#   { path, url, mirrors, hash }
#     a file, where hash is the SRI hash of the file, fetched from
#     `[ url ] ++ mirrors`
#   { path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash }
#     a git checkout, where hash is the SRI hash nix-prefetch-git reports.
#     opam installs a pinned checkout by its files, so the lock writes
#     leaveDotGit = false and commitObject = null.
#   { path, hg = { url, rev }, hash }
#     a Mercurial checkout, where hash is the SRI NAR hash
#   { path, darcs = { url, rev, context }, hash }
#     a Darcs checkout, where hash is the SRI NAR hash. Exactly one of
#     `rev` (a tag) and `context` (the text of a Darcs context file, which
#     names the repository head the lock run saw) is not null.
#
# By default a file is a fixed-output derivation on Nix's built-in fetcher
# (the derivation <nix/fetchurl.nix> makes). A fixed-output store path
# depends only on its name and hash, so the default fetcher and nixpkgs'
# fetchurl produce the same paths.
#
# `fetchurl`, when given, replaces the built-in fetcher for files. It is
# called with { name, urls, hash } and is the place for credentials
# (nixpkgs' fetchurl takes `netrcPhase`) or more mirrors. `fetchgit` is
# the place for credentials to private git repositories.
{
  lock,
  fetchgit,
  fetchhg,
  fetchdarcs,
  writeText,
  fetchurl ? null,
}:
download:
let
  name = lock.downloadName download;
  urls = [ download.url ] ++ download.mirrors;
in
if download ? git then
  fetchgit {
    inherit name;
    inherit (download.git) url rev leaveDotGit;
    fetchSubmodules = download.git.submodules;
    inherit (download) hash;
  }
else if download ? hg then
  fetchhg {
    inherit name;
    inherit (download.hg) url rev;
    inherit (download) hash;
  }
else if download ? darcs then
  fetchdarcs {
    inherit name;
    inherit (download.darcs) url rev;
    context =
      if download.darcs.context != null then writeText "${name}-context" download.darcs.context else null;
    inherit (download) hash;
  }
else if fetchurl != null then
  fetchurl {
    inherit name urls;
    inherit (download) hash;
  }
else
  derivation {
    inherit name;
    builder = "builtin:fetchurl";
    system = "builtin";
    url = download.url;
    inherit urls;
    outputHash = download.hash;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
