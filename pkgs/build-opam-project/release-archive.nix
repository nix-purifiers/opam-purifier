# SPDX-License-Identifier: MIT
#
# The release archive of an opam project: the project source as
# <name>-<version>.tar.gz, with the top directory <name>-<version>/, the
# layout opam's `url` section expects. The archive is reproducible: the
# entries are sorted, owned by 0:0, dated at the epoch, and gzip writes no
# name or time, so the same source gives the same bytes and checksum.
{
  pkgs,
  src,
  name,
  version,
}:
pkgs.runCommand "${name}-${version}-release"
  {
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.gzip
    ];
  }
  ''
    mkdir -p $out
    cp -r --no-preserve=mode ${src} "${name}-${version}"
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
      --format=gnu -cf - "${name}-${version}" | gzip -9 -n > "$out/${name}-${version}.tar.gz"
  ''
