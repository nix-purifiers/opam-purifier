# SPDX-License-Identifier: MIT
#
# The opam-purifier command: bin/opam-purifier on nixpkgs' Python, with
# the Nix library it builds lockfiles with and the nixpkgs those builds
# use. The lock run needs opam and what opam runs to fetch and unpack
# sources; the user's PATH comes first, for the user's nix.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  opam,
  curl,
  gitMinimal,
  mercurial,
  darcs,
  nix-prefetch-git,
  nix-prefetch-scripts,
  gnutar,
  gzip,
  bzip2,
  xz,
  unzip,
  rsync,
  gnupatch,
  diffutils,
  which,
  path,
  version,
}:
stdenvNoCC.mkDerivation {
  pname = "opam-purifier";
  inherit version;
  src = ../../bin;
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm644 opam-purifier "$out/libexec/opam-purifier.py"
    makeWrapper ${python3}/bin/python3 "$out/bin/opam-purifier" \
      --add-flags "$out/libexec/opam-purifier.py" \
      --set OPAM_PURIFIER_SELF "$out/bin/opam-purifier" \
      --set OPAM_PURIFIER_LIB ${../../nix/lib} \
      --set OPAM_PURIFIER_NIXPKGS ${path} \
      --suffix PATH : ${
        lib.makeBinPath [
          opam
          curl
          gitMinimal
          mercurial
          darcs
          nix-prefetch-git
          nix-prefetch-scripts
          gnutar
          gzip
          bzip2
          xz
          unzip
          rsync
          gnupatch
          diffutils
          which
        ]
      }
    runHook postInstall
  '';
  meta = {
    description = "Locks the files an opam project downloads, so that Nix can build it offline";
    license = lib.licenses.mit;
    mainProgram = "opam-purifier";
  };
}
