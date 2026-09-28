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
# TRUSTED-MACHINE TOOL, not a CI step.
# It sources the local keyring env on purpose: the keyring package is the thing
# the ROOT key signs, and the root secret never enters CI. A CI job must not
# call this file - stage S signs the day-to-day source with a subkey only.
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
URIs: $BASE/$DISTRO/$SUITE
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

# dpkg-deb is the tool for this, and the only one used: it is what any
# Debian-ish box (or the debian container this belongs in) has.
dpkg-deb --build --root-owner-group "$ROOT" "$DEB" > /dev/null
echo "  built with dpkg-deb"

echo "=== built $DEB ==="
ls -l "$DEB" | awk '{printf "  %s bytes\n", $5}'
echo "  --- contents ---"
( cd "$ROOT" && find . -type f ! -path './DEBIAN/*' | sort | sed 's/^/    /' )
echo "  --- control ---"
sed 's/^/    /' "$ROOT/DEBIAN/control"
echo
echo "  NEXT: re-sign the keyring source so it serves this package:"
echo "    bash lab/mkrepo-debian.sh <root-fpr> site/$DISTRO-keyring $SUITE"
