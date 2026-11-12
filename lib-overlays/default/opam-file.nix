# SPDX-License-Identifier: MIT
#
# Reads the sources of an opam file at evaluation: its `url` section and
# each `extra-source` section, the same list bin/opam-purifier reads with
# `sources_of`. Each source is
#
#   { name, src, checksums, mirrors }
#
# where `name` is null for the `url` section, and `checksums` lists the
# checksums in the order the file gives them, such as "sha256=<hex>".
#
# The parser reads only what it needs. A lexer splits the text into
# strings, punctuation and words, and drops comments. Sections are read
# at the top level of the file, where no bracket or brace is open, so a
# filter such as `{>= "1.0"}` in a list is never taken for one.
{ lib }:
text:
let
  # A triple-quoted string holds any text, quotes among it. The text
  # splits on `"""` first: the odd pieces are such strings.
  pieces = builtins.split ''"""'' text;
  outside = lib.imap0 (i: p: if lib.mod i 2 == 0 then p else null) (
    builtins.filter builtins.isString pieces
  );

  # The tokens outside triple-quoted strings. builtins.split scans from
  # the left, so a `#` or `(*` inside a string stays in the string.
  tokenRegex = ''
    ("([^"\\]|\\.)*"|\(\*|\*\)|#[^
    ]*|[][{}:])'';
  tokensOf =
    piece:
    lib.concatMap (
      part:
      if builtins.isList part then
        let
          m = builtins.head part;
        in
        if lib.hasPrefix "#" m then
          [ ]
        else if lib.hasPrefix ''"'' m then
          [
            {
              kind = "string";
              value = unescape (builtins.substring 1 (builtins.stringLength m - 2) m);
            }
          ]
        else if m == "(*" then
          [ { kind = "open-comment"; } ]
        else if m == "*)" then
          [ { kind = "close-comment"; } ]
        else
          [
            {
              kind = "punct";
              value = m;
            }
          ]
      else
        map (w: {
          kind = "word";
          value = w;
        }) (builtins.filter (w: builtins.isString w && w != "") (builtins.split "[[:space:]]+" part))
    ) (builtins.split tokenRegex piece);

  unescape =
    s:
    builtins.replaceStrings
      [
        "\\\\"
        "\\\""
        "\\n"
        "\\t"
      ]
      [
        "\\"
        "\""
        "\n"
        "\t"
      ]
      s;

  rawTokens = lib.concatMap (
    p:
    if p == null then
      [
        {
          kind = "string";
          value = "";
        }
      ]
    else
      tokensOf p
  ) outside;

  # Comments do not nest in opam files; a token inside one is dropped.
  tokens =
    (builtins.foldl'
      (
        acc: t:
        if t.kind == "open-comment" then
          acc // { inComment = true; }
        else if t.kind == "close-comment" then
          acc // { inComment = false; }
        else if acc.inComment then
          acc
        else
          acc // { out = acc.out ++ [ t ]; }
      )
      {
        inComment = false;
        out = [ ];
      }
      rawTokens
    ).out;

  count = builtins.length tokens;
  at = i: if i < count then builtins.elemAt tokens i else { kind = "end"; };
  isPunct = v: t: t.kind == "punct" && t.value == v;

  # The index after the bracketed value that opens at i.
  skipGroup =
    i:
    let
      go =
        j: depth:
        let
          t = at j;
        in
        if t.kind == "end" then
          j
        else if isPunct "[" t || isPunct "{" t then
          go (j + 1) (depth + 1)
        else if isPunct "]" t || isPunct "}" t then
          (if depth == 1 then j + 1 else go (j + 1) (depth - 1))
        else
          go (j + 1) depth;
    in
    go i 0;

  # The strings of a field value at i: one string, or a list of strings.
  stringsAt =
    i:
    let
      t = at i;
    in
    if t.kind == "string" then
      [ t.value ]
    else if isPunct "[" t then
      let
        go =
          j: acc:
          let
            u = at j;
          in
          if u.kind == "end" || isPunct "]" u then
            acc
          else if u.kind == "string" then
            go (j + 1) (acc ++ [ u.value ])
          else if isPunct "{" u || isPunct "[" u then
            go (skipGroup j) acc
          else
            go (j + 1) acc;
      in
      go (i + 1) [ ]
    else
      [ ];

  # The fields of the section whose body opens with `{` at i, as
  # { fields, next }, where next is the index after its `}`.
  section =
    i:
    let
      go =
        j: fields:
        let
          t = at j;
        in
        if t.kind == "end" || isPunct "}" t then
          {
            inherit fields;
            next = j + 1;
          }
        else if t.kind == "word" && isPunct ":" (at (j + 1)) then
          go (j + 2) (fields // { ${t.value} = stringsAt (j + 2); })
        else if isPunct "{" t || isPunct "[" t then
          go (skipGroup j) fields
        else
          go (j + 1) fields;
    in
    go (i + 1) { };

  # The older opam format names the source `archive`.
  sourceOf =
    name: fields:
    let
      src = if (fields.src or [ ]) != [ ] then fields.src else fields.archive or [ ];
    in
    if src != [ ] then
      [
        {
          inherit name;
          src = builtins.head src;
          checksums = fields.checksum or [ ];
          mirrors = fields.mirrors or [ ];
        }
      ]
    else
      [ ];

  # The sources at the top level, from token i on.
  sources =
    let
      go =
        i: acc:
        let
          t = at i;
          u = at (i + 1);
        in
        if t.kind == "end" then
          acc
        else if t.kind == "word" && t.value == "url" && isPunct "{" u then
          let
            s = section (i + 1);
          in
          go s.next (acc ++ sourceOf null s.fields)
        else if
          t.kind == "word" && t.value == "extra-source" && u.kind == "string" && isPunct "{" (at (i + 2))
        then
          let
            s = section (i + 2);
          in
          go s.next (acc ++ sourceOf u.value s.fields)
        else if isPunct "{" t || isPunct "[" t then
          go (skipGroup i) acc
        else
          go (i + 1) acc;
    in
    go 0 [ ];
in
sources
