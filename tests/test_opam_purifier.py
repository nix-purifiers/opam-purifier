# SPDX-License-Identifier: MIT
#
# Unit tests of bin/opam-purifier: the opam file parser, the source URLs,
# the download cache paths, the definition hash and the lock hash. The
# CLI package runs them in its install check, against the installed
# script: python3 tests/test_opam_purifier.py, with OPAM_PURIFIER_SCRIPT
# naming the script.
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest

script = os.environ.get(
    "OPAM_PURIFIER_SCRIPT",
    str(pathlib.Path(__file__).resolve().parent.parent / "bin" / "opam-purifier"),
)
loader = importlib.machinery.SourceFileLoader("opam_purifier", script)
spec = importlib.util.spec_from_loader("opam_purifier", loader)
assert spec is not None
op = importlib.util.module_from_spec(spec)
loader.exec_module(op)

OCAML_CONFIG = r'''
opam-version: "2.0"
name: "ocaml-config"
version: "3"
description:
  "This package is used by the OCaml package to set-up its variables."
depends: [
  "ocaml-base-compiler" {>= "5.0.0~" | os = "win32"} |
  "ocaml-system" {>= "5.0.0~" | os = "win32"}
]
substs: "gen_ocaml_config.ml"
extra-source "gen_ocaml_config.ml.in" {
  src:
    "https://raw.githubusercontent.com/ocaml/ocaml/66f33f6e/tools/opam/gen_ocaml_config.ml.in"
  checksum: [
    "sha256=a9ad8d84a08961159653a978db92d10f694510182b206cacb96d5c9f63b5121e"
    "md5=c0a50fb1f6ffe7a48bf8600e83ae6d38"
  ]
}
'''

WITH_URL = r'''
opam-version: "2.0"
(* A block comment, with "a string" inside. *)
# A line comment.
synopsis: """A triple-quoted "synopsis" """
build: [
  ["dune" "build" "-p" name "-j" jobs]
  ["dune" "runtest" "-p" name] {with-test & os != "macos"}
]
url {
  src: "https://example.org/foo-1.0.tbz"
  checksum: "sha256=0000000000000000000000000000000000000000000000000000000000000000"
  mirrors: [ "https://mirror.example.org/foo-1.0.tbz" ]
}
'''


class OpamFileTest(unittest.TestCase):
    def test_fields_and_sections(self):
        opam = op.OpamFile(OCAML_CONFIG)
        self.assertEqual(opam.string("name"), "ocaml-config")
        self.assertEqual(opam.string("version"), "3")
        self.assertEqual([s[0] for s in opam.sections], ["extra-source"])
        self.assertEqual(opam.sections[0][1], "gen_ocaml_config.ml.in")

    def test_comments_and_triple_quotes(self):
        opam = op.OpamFile(WITH_URL)
        self.assertEqual(opam.string("synopsis"), 'A triple-quoted "synopsis" ')
        self.assertIn("build", opam.fields)

    def test_escapes(self):
        opam = op.OpamFile('name: "a\\"b\\\\c\\n"\n')
        self.assertEqual(opam.string("name"), 'a"b\\c\n')

    def test_unclosed_section(self):
        with self.assertRaises(ValueError):
            op.OpamFile('url {\n  src: "x"\n')


class SourcesTest(unittest.TestCase):
    def test_extra_source(self):
        (source,) = op.sources_of(OCAML_CONFIG)
        self.assertEqual(source["name"], "gen_ocaml_config.ml.in")
        self.assertTrue(source["src"].startswith("https://raw.githubusercontent.com/"))
        self.assertEqual(len(source["checksums"]), 2)
        self.assertEqual(source["mirrors"], [])

    def test_url_with_mirrors(self):
        (source,) = op.sources_of(WITH_URL)
        self.assertEqual(source["src"], "https://example.org/foo-1.0.tbz")
        self.assertEqual(source["mirrors"], ["https://mirror.example.org/foo-1.0.tbz"])
        self.assertEqual(len(source["checksums"]), 1)

    def test_pin_depends(self):
        one = op.pin_depends_of('pin-depends: ["a.1" "git+https://x/a.git"]\n')
        self.assertEqual(one, [("a.1", "git+https://x/a.git")])
        many = op.pin_depends_of(
            'pin-depends: [\n  ["a.1" "git+https://x/a.git#v1"]\n  ["b.2" "https://x/b.tar.gz"]\n]\n'
        )
        self.assertEqual(many, [("a.1", "git+https://x/a.git#v1"), ("b.2", "https://x/b.tar.gz")])
        self.assertEqual(op.pin_depends_of('name: "x"\n'), [])


class UrlTest(unittest.TestCase):
    def test_vcs_kinds(self):
        self.assertEqual(op.vcs_of("git+https://github.com/a/b.git#v1"), "git")
        self.assertEqual(op.vcs_of("git://github.com/a/b"), "git")
        self.assertEqual(op.vcs_of("https://github.com/a/b.git"), "git")
        self.assertEqual(op.vcs_of("hg+https://hg.example.org/b"), "hg")
        self.assertEqual(op.vcs_of("darcs+https://hub.darcs.net/a/b#t"), "darcs")
        self.assertIsNone(op.vcs_of("https://example.org/b-1.0.tar.gz"))

    def test_split(self):
        self.assertEqual(op.split_vcs("git+https://github.com/a/b.git#v1"), ("https://github.com/a/b.git", "v1"))
        self.assertEqual(op.split_vcs("hg+https://hg.example.org/b"), ("https://hg.example.org/b", ""))

    def test_ssh_becomes_https(self):
        self.assertEqual(
            op.split_vcs("git+ssh://git@github.com/a/b.git#main"), ("https://github.com/a/b.git", "main")
        )
        self.assertEqual(op.split_vcs("git@gitlab.com:a/b.git"), ("https://gitlab.com/a/b.git", ""))

    def test_cache(self):
        checksum = "sha256=472798691b0216daf538709f0f4703b3617ef24ad0866c9096068baaba4d762a"
        self.assertEqual(
            op.cache_path(checksum),
            "download-cache/sha256/47/472798691b0216daf538709f0f4703b3617ef24ad0866c9096068baaba4d762a",
        )
        self.assertEqual(
            op.cache_url(checksum),
            "https://opam.ocaml.org/cache/sha256/47/472798691b0216daf538709f0f4703b3617ef24ad0866c9096068baaba4d762a",
        )


class HashTest(unittest.TestCase):
    def test_definition_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "b.opam").write_text('opam-version: "2.0"\n')
            (root / "a.opam").write_text('opam-version: "2.0"\nname: "a"\n')
            (root / "notes.txt").write_text("not a definition file")
            options = {"withTest": True, "repositories": []}
            manifest = "".join(
                f"{name}\t{hashlib.sha256((root / name).read_bytes()).hexdigest()}\n"
                for name in ("a.opam", "b.opam")
            ) + 'options\t{"repositories":[],"withTest":true}\n'
            expected = "sha256:" + hashlib.sha256(manifest.encode()).hexdigest()
            self.assertEqual(op.definition_hash(root, options), expected)
            (root / "notes.txt").write_text("changed")
            self.assertEqual(op.definition_hash(root, options), expected)
            (root / "a.opam").write_text('opam-version: "2.0"\nname: "a"\nversion: "2"\n')
            self.assertNotEqual(op.definition_hash(root, options), expected)

    def test_lock_hash(self):
        lock = {"version": 1, "b": ["é", "x\ny"], "a": {"z": None, "y": True}}
        text = '{"a":{"y":true,"z":null},"b":["é","x\\ny"],"version":1}'
        expected = "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()
        self.assertEqual(op.lock_hash(lock), expected)
        lock["lockHash"] = "sha256:anything"
        self.assertEqual(op.lock_hash(lock), expected)

    def test_write_lock_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            op.write_lock(root, {"version": 1, "packages": []})
            data = json.loads((root / op.LOCK_FILE).read_text())
            self.assertEqual(data["lockHash"], op.lock_hash(data))


if __name__ == "__main__":
    unittest.main()
