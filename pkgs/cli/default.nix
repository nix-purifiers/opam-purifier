# SPDX-License-Identifier: MIT
#
# The opam-purifier command: bin/opam-purifier on nixpkgs' Python, with
# the Nix library it builds with, the purifier library that library
# fetches through, and the nixpkgs those builds use. The lock run needs opam and what opam runs to fetch and unpack
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
  # The source of the shared purifier library, which the default package
  # overlay passes.
  purifierSource,
}:
let
  library =
    if purifierSource == null then
      throw "opam-purifier: the cli package needs the source of the purifier library; take it from the flake's package overlay"
    else
      purifierSource;
in
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
      --set OPAM_PURIFIER_PURIFIER ${library} \
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
  # The unit tests of the script (tests/test_opam_purifier.py) run
  # against the installed copy.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    OPAM_PURIFIER_SCRIPT="$out/libexec/opam-purifier.py" \
      ${python3}/bin/python3 ${../../tests/test_opam_purifier.py} -v
    runHook postInstallCheck
  '';
  meta = {
    description = "Locks the files an opam project downloads, so that Nix can build it offline";
    license = lib.licenses.mit;
    mainProgram = "opam-purifier";
  };
}
