#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI.
#
# Builds <repo>-archive-keyring: the one .deb a consumer installs to get BOTH
# sources configured. Debian's own wiki explicitly allows this shape - a
# keyring package MUST ship the certificates under /usr/share/keyrings and MAY
# also ship sources.list.d entries.
#
# What it carries:
#   /usr/share/keyrings/qmdmm-root.gpg        root public key only
#   /usr/share/keyrings/qmdmm-packages.gpg    root + this line's signing subkey
#   /etc/apt/sources.list.d/qmdmm.sources     both repos, each naming its file
#
# Note there is deliberately no .deb signature. apt does not review signatures
# at the package level at all; what protects this package is that it is served
# from the ROOT-signed keyring source, whose InRelease only the root key can
# sign. That is the whole reason the keyring source exists as a separate repo.
#
# usage: mkkeyring-deb.sh <distro> <pages-base> [version]
set -euo pipefail

cd "$(dirname "$0")/.."                      # -> repo/
source "$HOME/qmdmm-signing-lab/env.sh"      # GNUPGHOME
source lab/lib-tools.sh                      # md5_of

DISTRO="${1:?usage: mkkeyring-deb.sh <distro> <pages-base> [version]}"
BASE="${2:?usage: mkkeyring-deb.sh <distro> <pages-base> [version]}"
VERSION="${3:-$(date -u +%Y.%m.%d).1}"
SUITE="${SUITE:-sid}"
PKG="qmdmm-archive-keyring"

[ -f "keys/$DISTRO/qmdmm-packages.gpg" ] || { echo "!! keys/$DISTRO/qmdmm-packages.gpg missing"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/share/keyrings" "$ROOT/etc/apt/sources.list.d"

cp keys/qmdmm-root.gpg            "$ROOT/usr/share/keyrings/qmdmm-root.gpg"
cp "keys/$DISTRO/qmdmm-packages.gpg" "$ROOT/usr/share/keyrings/qmdmm-packages.gpg"
chmod 644 "$ROOT/usr/share/keyrings/"*.gpg

cat > "$ROOT/etc/apt/sources.list.d/qmdmm.sources" <<EOF
Types: deb
URIs: $BASE/$DISTRO-keyring
Suites: $SUITE
Components: main
Signed-By: /usr/share/keyrings/qmdmm-root.gpg

Types: deb
URIs: $BASE/$DISTRO
Suites: $SUITE
Components: main
Signed-By: /usr/share/keyrings/qmdmm-packages.gpg
EOF
chmod 644 "$ROOT/etc/apt/sources.list.d/qmdmm.sources"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: QMdmm signing lab <lab@example.invalid>
Section: misc
Priority: optional
Description: QMdmm archive signing keys and repository configuration
 Ships the QMdmm root public key, this distribution's operational
 subkey, and the sources.list.d entries for both the keyring source
 and the day-to-day source. Installing it configures both repos.
EOF

# md5sums, as a package should have
( cd "$ROOT" && find . -type f ! -path './DEBIAN/*' | sed 's|^\./||' | sort | \
  while read -r f; do printf '%s  %s\n' "$(md5_of "$f")" "$f"; done \
) > "$ROOT/DEBIAN/md5sums"

POOL="site/$DISTRO-keyring/pool/main/q/$PKG"
mkdir -p "$POOL"
rm -f "$POOL"/*.deb
DEB="$(cd "$POOL" && pwd)/${PKG}_${VERSION}_all.deb"

# A .deb is an ar archive holding debian-binary, control.tar.gz and data.tar.gz.
#
# Use dpkg-deb when it exists: that is what any Debian-ish box has, and what the
# real pipeline will run on. The fallback below only exists because this lab is
# driven from a Mac - macOS has no dpkg-deb, and its ar is a Mach-O archiver
# that would produce a broken container.
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb --build --root-owner-group "$ROOT" "$DEB" > /dev/null
  echo "  built with dpkg-deb"
else
  echo "  no dpkg-deb here (a Mac) - writing the ar container directly"
  ( cd "$ROOT/DEBIAN" && tar --uid 0 --gid 0 --uname root --gname root -czf "$WORK/control.tar.gz" . )
  ( cd "$ROOT" && tar --uid 0 --gid 0 --uname root --gname root --exclude ./DEBIAN \
      -czf "$WORK/data.tar.gz" . )
  printf '2.0\n' > "$WORK/debian-binary"
  python3 - "$DEB" "$WORK/debian-binary" "$WORK/control.tar.gz" "$WORK/data.tar.gz" <<'PY'
import sys, time

def field(b, n):
    return b + b" " * (n - len(b))

def member(name, data):
    hdr  = field(name.encode(), 16)
    hdr += field(b"%d" % int(time.time()), 12)
    hdr += field(b"0", 6)          # uid
    hdr += field(b"0", 6)          # gid
    hdr += field(b"100644", 8)     # mode
    hdr += field(b"%d" % len(data), 10)
    hdr += b"`\n"
    body = hdr + data
    if len(data) % 2:
        body += b"\n"              # members are padded to even length
    return body

out = sys.argv[1]
with open(out, "wb") as f:
    f.write(b"!<arch>\n")
    for path in sys.argv[2:]:
        f.write(member(path.split("/")[-1], open(path, "rb").read()))
PY
fi

echo "=== built $DEB ==="
ls -l "$DEB" | awk '{printf "  %s bytes\n", $5}'
echo "  --- contents ---"
( cd "$ROOT" && find . -type f ! -path './DEBIAN/*' | sort | sed 's/^/    /' )
echo "  --- control ---"
sed 's/^/    /' "$ROOT/DEBIAN/control"
echo
echo "  NEXT: re-sign the keyring source so it serves this package:"
echo "    bash lab/mkrepo-debian.sh <root-fpr> site/$DISTRO-keyring $SUITE"
