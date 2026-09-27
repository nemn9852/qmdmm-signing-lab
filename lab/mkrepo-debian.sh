#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI.
#
# Builds a minimal apt repository tree and signs its InRelease with a given key.
# Used for the parts of the scheme that must not go through CI:
#
#   - the keyring source, which only the root key may sign (if the trust root
#     never enters a workflow, a compromised workflow cannot replace it);
#   - frozen fixtures, e.g. "a source signed by the subkey that was later
#     revoked", kept around so a consumer-side test can prove it gets rejected.
#
# usage: mkrepo-debian.sh <key-fpr> <outdir> [suite] [description]
set -euo pipefail

KEY="${1:?usage: mkrepo-debian.sh <key-fpr> <outdir> [suite] [description]}"
OUT="${2:?usage: mkrepo-debian.sh <key-fpr> <outdir> [suite] [description]}"
SUITE="${3:-sid}"
DESC="${4:-QMdmm signing lab apt repository}"

cd "$(dirname "$0")/.."                      # -> repo/
# No local keyring is sourced here: this used to do
#   source "$HOME/qmdmm-signing-lab/env.sh"
# which is a trusted-machine file and does not exist in CI - it took all five deb
# rows down with "No such file or directory" while the rpm and pacman rows passed.
# The key is an argument; the keyring is whatever the calling script imported.
source lab/lib-tools.sh                      # md5_of / sha_of / deb_control

D="$OUT/dists/$SUITE"
ARCHDIR="$D/main/binary-all"

echo "=== building $OUT (suite $SUITE) with key $KEY ==="

mkdir -p "$ARCHDIR"
# If the repo carries packages in pool/, describe them for real (control is
# read straight out of the .deb with ar+tar, since there is no dpkg-deb).
# Otherwise emit a placeholder entry so Release still has something to list.
found=0
while IFS= read -r deb; do
  rel="${deb#"$OUT"/}"
  ctrl=$(deb_control "$deb")
  printf '%s\n' "$ctrl" | grep -v '^$'
  printf 'Filename: %s\n' "$rel"
  printf 'Size: %s\n' "$(wc -c < "$deb" | tr -d ' ')"
  printf 'MD5sum: %s\n' "$(md5_of "$deb")"
  printf 'SHA256: %s\n' "$(sha_of "$deb")"
  printf '\n'
  found=1
done < <(find "$OUT/pool" -name '*.deb' 2>/dev/null | sort) > "$ARCHDIR/Packages"
if [ "$found" = 0 ]; then
  {
    echo "Package: qmdmm-lab"
    echo "Version: 1.0"
    echo "Architecture: all"
    echo "Maintainer: QMdmm signing lab <lab@example.invalid>"
    echo "Description: $DESC"
  } > "$ARCHDIR/Packages"
fi
gzip -kf "$ARCHDIR/Packages"

{
  echo "Origin: QMdmm Signing Lab"
  echo "Label: QMdmm Signing Lab"
  echo "Suite: stable"
  echo "Codename: stable"
  echo "Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  echo "Architectures: all"
  echo "Components: main"
  echo "Description: $DESC"
  echo "MD5Sum:"
  printf ' %s %16s %s\n' "$(md5_of "$ARCHDIR/Packages")"    "$(wc -c < "$ARCHDIR/Packages"    | tr -d ' ')" "main/binary-all/Packages"
  printf ' %s %16s %s\n' "$(md5_of "$ARCHDIR/Packages.gz")" "$(wc -c < "$ARCHDIR/Packages.gz" | tr -d ' ')" "main/binary-all/Packages.gz"
  echo "SHA256:"
  printf ' %s %16s %s\n' "$(sha_of "$ARCHDIR/Packages")"    "$(wc -c < "$ARCHDIR/Packages"    | tr -d ' ')" "main/binary-all/Packages"
  printf ' %s %16s %s\n' "$(sha_of "$ARCHDIR/Packages.gz")" "$(wc -c < "$ARCHDIR/Packages.gz" | tr -d ' ')" "main/binary-all/Packages.gz"
} > "$D/Release"

gpg --batch --yes --local-user "${KEY}!" --clearsign -o "$D/InRelease" "$D/Release"

echo "  --- who signed it ---"
gpg --verify "$D/InRelease" 2>&1 | sed 's/^/    /'
echo "  --- output ---"
find "$OUT" -type f | sort | sed 's/^/    /'
