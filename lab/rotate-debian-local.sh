#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI. Rotates ONE distro line's signing
# subkey while leaving the root key - the trust anchor - exactly where it is.
#
#   1. freeze the current day-to-day source (signed by the outgoing subkey) as
#      a fixture, so a consumer-side test can prove it is rejected afterwards
#   2. revoke the outgoing subkey
#   3. add a fresh signing subkey
#   4. re-sign the keyring source with the root key
#   5. re-export that line's public key file: root + outgoing[revoked] + new
#      (carrying the revoked subkey means a consumer sees "revoked", not just
#       "unknown key")
#   6. write the new subkey's secret for the CI environment
#
# What does NOT happen: the root key is not touched, no other line's subkey is
# touched, and nothing here needs CI credentials.
#
# usage: rotate-debian-local.sh <distro>        (currently: debian)
set -euo pipefail

DISTRO="${1:?usage: rotate-debian-local.sh <distro>}"
cd "$(dirname "$0")/.."                      # -> repo/
source "$HOME/qmdmm-signing-lab/env.sh"      # GNUPGHOME, ROOT, SUB_*

case "$DISTRO" in
  debian) OLD_SUB="$SUB_DEBIAN" ;;
  *) echo "unsupported distro: $DISTRO"; exit 1 ;;
esac
PKGFILE="keys/$DISTRO/qmdmm-packages.gpg"

OLDKEYID="${OLD_SUB: -16}"

echo "=== scope ==="
echo "  root            = $ROOT   (untouched)"
echo "  outgoing subkey = $OLD_SUB"

echo
echo "=== 1) freeze the current day-to-day source as a fixture ==="
bash lab/mkrepo-debian.sh "$OLD_SUB" "site/$DISTRO-revoked" sid \
     "frozen snapshot, signed by the subkey that is revoked next"

echo
echo "=== 2) revoke the outgoing subkey ==="
printf 'key %s\nrevkey\ny\n0\n\ny\nsave\n' "$OLDKEYID" | \
  gpg --batch --command-fd 0 --status-fd 2 --edit-key "$ROOT" > /dev/null 2>&1
echo "  subkey revocation flags now:"
gpg --with-colons --list-keys "$ROOT" 2>/dev/null \
  | awk -F: '/^sub:/{printf "    sub rev=%s keyid=%s\n", $2, $5}'

echo
echo "=== 3) add a fresh signing subkey ==="
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$ROOT" ed25519 sign 0 2>&1 | tail -2 || true
NEW_SUB=$(gpg --with-colons --list-secret-keys "$ROOT" 2>/dev/null \
            | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}' | tail -1)
if [ -z "$NEW_SUB" ] || [ "$NEW_SUB" = "$OLD_SUB" ]; then
  echo "  !! could not determine the new subkey"; exit 1
fi
echo "  new subkey = $NEW_SUB"

echo
echo "=== 4) re-sign the keyring source with the root key ==="
bash lab/mkrepo-debian.sh "$ROOT" "site/$DISTRO-keyring" sid \
     "keyring source (root-signed)"

echo
echo "=== 5) re-export this line's public key file ==="
echo "  (root + outgoing[revoked] + new)"
gpg --batch --armor --export "${OLD_SUB}!" "${NEW_SUB}!" > "$LAB/pub-$DISTRO.asc"
gpg --dearmor < "$LAB/pub-$DISTRO.asc" > "$PKGFILE"
python3 "$LAB/pktstat.py" "$LAB/pub-$DISTRO.asc" | sed 's/^/    /'

echo
echo "=== 6) write the new secret for the CI environment ==="
gpg --batch --armor --export-secret-subkeys "${NEW_SUB}!" > "$LAB/priv-$DISTRO.asc"
openssl base64 -A -in "$LAB/priv-$DISTRO.asc" -out "$LAB/priv-$DISTRO.b64"
echo "  wrote $LAB/priv-$DISTRO.b64 ($(wc -c < "$LAB/priv-$DISTRO.b64" | tr -d ' ') bytes)"
echo "  upload: gh secret set SIGNING_KEY --repo $LAB_REPO --env $DISTRO < $LAB/priv-$DISTRO.b64"

# keep env.sh pointing at the live subkey so the next run rotates the right one
sed -i "s|^export SUB_${DISTRO^^}=.*|export SUB_${DISTRO^^}=$NEW_SUB|" "$LAB/env.sh"
echo
echo "NEW_SUB=$NEW_SUB"
