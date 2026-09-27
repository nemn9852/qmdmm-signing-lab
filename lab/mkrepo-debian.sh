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
source "$HOME/qmdmm-signing-lab/env.sh"      # GNUPGHOME

D="$OUT/dists/$SUITE"
ARCHDIR="$D/main/binary-all"

echo "=== building $OUT (suite $SUITE) with key $KEY ==="

# apt wants per-file checksums in Release; there is no apt-ftparchive here, so
# compute them. md5/shasum keep this portable to macOS.
md5_of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$ARCHDIR"
# If the repo carries packages in pool/, describe them for real (control is
# read straight out of the .deb with ar+tar, since there is no dpkg-deb).
# Otherwise emit a placeholder entry so Release still has something to list.
found=0
while IFS= read -r deb; do
  rel="${deb#"$OUT"/}"
  # Read control straight out of the .deb. No dpkg-deb here, and macOS's ar is
  # a Mach-O archiver, so parse the ar container ourselves.
  ctrl=$(python3 - "$deb" <<'PY'
import sys, io, tarfile
d = open(sys.argv[1], "rb").read()
if d[:8] == b"!<arch>\n":
    i = 8
    while i + 60 <= len(d):
        hdr = d[i:i+60]
        name = hdr[0:16].decode(errors="replace").strip()
        size = int(hdr[48:58].decode().strip() or 0)
        body = d[i+60:i+60+size]
        if name.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(body)) as tf:
                for m in tf.getmembers():
                    if m.name.lstrip("./") == "control":
                        sys.stdout.write(tf.extractfile(m).read().decode())
            break
        i += 60 + size + (size % 2)
PY
)
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
