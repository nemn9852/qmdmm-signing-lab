#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI.
#
# Signs the Debian keyring source with the *root* key. This is the one thing in
# the whole scheme that must be root-signed, which is exactly why it is kept out
# of CI and signed by hand: if the trust root never enters a workflow, a
# compromised workflow cannot replace it.
#
# Produces repo/debian/keyring/dists/stable/{Release,InRelease} + Packages.
set -euo pipefail

cd "$(dirname "$0")/.."                      # -> repo/
source "$HOME/qmdmm-signing-lab/env.sh"      # GNUPGHOME + ROOT fingerprint

OUT="repo/debian/keyring"
D="$OUT/dists/stable"
ARCHDIR="$D/main/binary-all"

echo "=== signing the keyring source with the root key ==="
echo "  root fpr = $ROOT"

mkdir -p "$ARCHDIR"
: > "$ARCHDIR/Packages"
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
  echo "Description: QMdmm signing lab - keyring source (root-signed)"
  echo "MD5Sum:"
  printf ' %s %16s %s\n' "$(md5_of "$ARCHDIR/Packages")"    "$(wc -c < "$ARCHDIR/Packages"    | tr -d ' ')" "main/binary-all/Packages"
  printf ' %s %16s %s\n' "$(md5_of "$ARCHDIR/Packages.gz")" "$(wc -c < "$ARCHDIR/Packages.gz" | tr -d ' ')" "main/binary-all/Packages.gz"
  echo "SHA256:"
  printf ' %s %16s %s\n' "$(sha_of "$ARCHDIR/Packages")"    "$(wc -c < "$ARCHDIR/Packages"    | tr -d ' ')" "main/binary-all/Packages"
  printf ' %s %16s %s\n' "$(sha_of "$ARCHDIR/Packages.gz")" "$(wc -c < "$ARCHDIR/Packages.gz" | tr -d ' ')" "main/binary-all/Packages.gz"
} > "$D/Release"

gpg --batch --yes --local-user "${ROOT}!" --clearsign -o "$D/InRelease" "$D/Release"

echo "  --- who signed it ---"
gpg --verify "$D/InRelease" 2>&1 | sed 's/^/    /'
echo "  --- output ---"
find "$OUT" -type f | sort | sed 's/^/    /'
