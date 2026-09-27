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

# The secret arrives as $SIGNING_KEY_B64, or on stdin as a single base64 line.
# (An earlier revision blamed stdin for "not reaching the container"; the probe
#  step in the workflow disproved that. The real bug was dropping `base64 -d`.)
KEY_B64="${SIGNING_KEY_B64:-}"
if [ -z "$KEY_B64" ]; then
  # Read stdin FIRST - apt-get below consumes it.
  IFS= read -r KEY_B64 || true
fi

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
printf '%s\n' "$KEY_B64" | base64 -d | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64

echo "  --- secret view (sec# = primary secret absent, as designed) ---"
gpg --list-secret-keys --keyid-format=long | sed 's/^/  /'
echo "  --- private key files (expect exactly 1: this line's subkey) ---"
ls -l "$HOME/.gnupg/private-keys-v1.d/" | sed 's/^/  /'

echo
echo "=== assert: the root secret is not usable inside this container ==="
echo "  private key files: $(ls "$HOME/.gnupg/private-keys-v1.d/" 2>/dev/null | wc -l | tr -d ' ')"
echo "  secret record types: $(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '{printf "%s ", $1}')"
ROOTFP=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
PROBE=$(mktemp)
if printf 'probe\n' | gpg --batch --local-user "${ROOTFP}!" --detach-sign -o "$PROBE" 2>/dev/null; then
  rm -f "$PROBE"; echo "  !! the primary secret can sign here - contradicts the design"; exit 1
fi
rm -f "$PROBE"
echo "  OK: gpg refuses to sign with the primary key"
echo "  (/dev/null check after using gpg: $(ls -ld /dev/null 2>&1 | tr -s ' ' | cut -d' ' -f1,5,9))"

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
