# 7-Zip command-line helper

The packaged app bundles the unmodified `7zz` command-line executable built
from this source archive. The helper is a separate process; Retron Commander
does not link to the 7-Zip library.

- Version: 26.04
- Upstream: <https://github.com/ip7z/7zip>
- Source archive: `7z2604-src.tar.xz`
- SHA-256: `9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6`
- Licenses: GNU LGPL-2.1-or-later, with BSD-2-Clause and BSD-3-Clause portions.
  See [License.txt](License.txt) and the individual source notices in the
  archive. The unRAR source restriction applies to RAR decompression code.

`Scripts/package-app.sh` expects the local `7zz` executable to be version
26.04, copies it into the app bundle, and includes this source archive and
license information beside it.
