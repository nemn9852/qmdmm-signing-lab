#!/usr/bin/env bash
#
# Sign a throwaway apt repository ("day-to-day" source) inside a real
# debian:sid container, using the per-distro subkey whose secret arrives
# on stdin as a single base64 line.
#
# Contract:
#   stdin  : one line, base64 of `gpg --armor --export-secret-subkeys "<fpr>!"`
#   env    : SUB_FPR = fingerprint of this line's signing subkey
#            OUT     = output dir inside the container (default /w/out/debian)
#
# The secret never appears in argv, in the environment, or in a log line.
set -euo pipefail

# Read the secret off stdin FIRST: apt-get below consumes stdin.
IFS= read -r KEY_B64 || true

SUB_FPR="${SUB_FPR:?SUB_FPR not set}"
OUT="${OUT:-/w/out/debian}"
DAILY="$OUT/daily"

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg:  $(gpg --version | head -1)"
echo "  arch: $(dpkg --print-architecture)"

echo
echo "=== dependencies ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq </dev/null
apt-get install -y -qq --no-install-recommends \
    gnupg gpgv apt-utils gzip ca-certificates </dev/null

echo
echo "=== import subkey from stdin ==="
printf '%s\n' "$KEY_B64" | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64

echo "  --- secret view (sec# = primary secret absent, as designed) ---"
gpg --list-secret-keys --keyid-format=long | sed 's/^/  /'
echo "  --- private key files (expect exactly 1: this line's subkey) ---"
ls -l "$HOME/.gnupg/private-keys-v1.d/" | sed 's/^/  /'

echo
echo "=== assert: no usable primary secret in this container ==="
if gpg --list-secret-keys --with-colons | awk -F: '$1=="sec" && $2!="e"' | grep -q .; then
  echo "  !! a usable primary secret is present - contradicts the design"; exit 1
fi
echo "  OK"

echo
echo "=== build the day-to-day source (InRelease signed by this line's subkey) ==="
mkdir -p "$DAILY/dists/stable/main/binary-all"
: > "$DAILY/dists/stable/main/binary-all/Packages"
gzip -kf "$DAILY/dists/stable/main/binary-all/Packages"
( cd "$DAILY/dists/stable" && apt-ftparchive release . > Release )
gpg --batch --yes --local-user "${SUB_FPR}!" --clearsign \
    -o "$DAILY/dists/stable/InRelease" "$DAILY/dists/stable/Release"

echo "  --- who signed it (expect the root uid + the subkey fingerprint) ---"
gpg --verify "$DAILY/dists/stable/InRelease" 2>&1 | sed 's/^/  /'

echo
echo "=== output ==="
find "$OUT" -type f | sort | sed 's/^/  /'
