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
# usage: mkrepo-debian.sh <key-fpr> <outdir> [description]
set -euo pipefail

KEY="${1:?usage: mkrepo-debian.sh <key-fpr> <outdir> [description]}"
OUT="${2:?usage: mkrepo-debian.sh <key-fpr> <outdir> [description]}"
DESC="${3:-QMdmm signing lab apt repository}"

cd "$(dirname "$0")/.."                      # -> repo/
source "$HOME/qmdmm-signing-lab/env.sh"      # GNUPGHOME

D="$OUT/dists/stable"
ARCHDIR="$D/main/binary-all"

echo "=== building $OUT with key $KEY ==="
mkdir -p "$ARCHDIR"
{
  echo "Package: qmdmm-lab"
  echo "Version: 1.0"
  echo "Architecture: all"
  echo "Maintainer: QMdmm signing lab <lab@example.invalid>"
  echo "Description: $DESC"
} > "$ARCHDIR/Packages"
gzip -kf "$ARCHDIR/Packages"

# apt wants per-file checksums in Release; there is no apt-ftparchive here, so
# compute them. md5/shasum keep this portable to macOS.
md5_of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

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
