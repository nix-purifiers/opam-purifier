# SPDX-License-Identifier: MIT
#
# Checks that the Nix parser of opam files (lib-overlays/default/opam-file.nix) reads the
# same sources as the parser of the command (`sources_of` in
# bin/opam-purifier), on the opam files of a real lockfile:
#
#   python3 check_parser.py SCRIPT EXPECTED.json TEXTS_DIR
#
# EXPECTED.json maps each package to the sources the Nix parser read from
# its opam file, and TEXTS_DIR holds the opam file of each package under the
# package's name.
import importlib.machinery
import importlib.util
import json
import pathlib
import sys

script, expected_file, texts_dir = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("opam_purifier", script)
spec = importlib.util.spec_from_loader("opam_purifier", loader)
assert spec is not None
op = importlib.util.module_from_spec(spec)
loader.exec_module(op)

expected = json.loads(pathlib.Path(expected_file).read_text())
disagreements = []
for package, nix_sources in sorted(expected.items()):
    text = (pathlib.Path(texts_dir) / package).read_text()
    try:
        python_sources = op.sources_of(text)
    except ValueError as error:
        python_sources = f"fails: {error}"
    if python_sources != nix_sources:
        disagreements.append((package, python_sources, nix_sources))

for package, python_sources, nix_sources in disagreements:
    print(f"{package}: the command reads {python_sources}, the Nix parser reads {nix_sources}", file=sys.stderr)
if disagreements:
    sys.exit(1)
print(f"the two parsers agree on {len(expected)} opam files")
