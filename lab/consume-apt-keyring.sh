#!/usr/bin/env bash
#
# Stage B for the part of the scheme that is not a day-to-day repository: the
# root-signed keyring source, and the fixture that proves revocation bites.
#
# This is a single cell rather than a row in the twelve-row matrix, because both
# directories are produced on a trusted machine (the root secret never enters a
# workflow), so there is one of each regardless of how many lines exist.
#
#   env: PAGES, ROOT_FPR, EXPECT_SHA
#
# What is checked:
#   A. the keyring source verifies under the ROOT public key alone, and the
#      signer really is the root key - not a subkey that happens to be in the
#      same file. That is the whole point of the keyring source existing as its
#      own repository: it is the one thing only the root key may sign.
#   B. the fixture signed by the subkey that was later revoked is reported as
#      signed by a REVOKED key, not silently accepted.
#
# B is written against `--status-fd` on purpose. FINDINGS.md 3.1: `gpg --verify`
# prints "Good signature" and exits 0 for a revoked signer, adding only a
# WARNING line, so any assertion built on its exit code or on grepping "Good
# signature" would pass on exactly the input it is meant to catch. The status
# stream says REVKEYSIG / KEYREVOKED, and that is what gets asserted here.
set -euo pipefail

PAGES="${PAGES:?}"; ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys" "$W/keyring" "$W/revoked"
source "$(dirname "$0")/lib-site.sh"

ROOT_KEYID="${ROOT_FPR: -16}"

echo "=== B/keyring (root-signed source + revoked fixture) ==="
echo "  $(os_name)"

echo
echo "--- tooling ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq </dev/null
# gpgv is its own package in Debian - gnupg does not pull it in - and this script
# is written against gpgv, so it has to be asked for by name. (It was not, and
# the first run got as far as `gpgv: command not found` before giving up.)
apt-get install -y -qq --no-install-recommends gnupg gpgv curl ca-certificates </dev/null
command -v gpgv >/dev/null \
  || { echo "  !! gpgv is missing, and every check below is written against it"; exit 1; }
echo "  gpgv: $(command -v gpgv)"

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- keys, from Pages only ---"
fetch "$PAGES/keys/qmdmm-root.gpg"           "$W/keys/root.gpg"
fetch "$PAGES/keys/debian/qmdmm-packages.gpg" "$W/keys/packages.gpg"
[ "$(key_fpr "$W/keys/root.gpg")" = "$ROOT_FPR" ] \
  || { echo "  !! the root key file is not $ROOT_FPR"; exit 1; }
echo "  root file:     $(count_subkeys "$W/keys/root.gpg") subkey(s), as it must have"
echo "  packages file: $(count_subkeys "$W/keys/packages.gpg") subkey(s), revoked one included"

echo
echo "--- fetch both off-CI sources ---"
fetch "$PAGES/debian-keyring/dists/sid/InRelease" "$W/keyring/InRelease"
fetch "$PAGES/debian-revoked/dists/sid/InRelease"  "$W/revoked/InRelease"

echo
echo "--- A) the keyring source, verified under the ROOT key alone ---"
# --status-fd is the machine-readable half of the answer; the human text is kept
# only for the log.
gpgv --keyring "$W/keys/root.gpg" --status-fd 3 "$W/keyring/InRelease" \
     3> "$W/status.a" 2> "$W/gpgv.a" || true
sed 's/^/    /' "$W/gpgv.a"
signer=$(awk '/^\[GNUPG:\] GOODSIG /{print $3}' "$W/status.a" | head -1)
if [ -z "$signer" ]; then
  echo "  !! the keyring source does not verify under the root key at all"
  sed 's/^/    /' "$W/status.a"; exit 1
fi
echo "  signer: $signer   expected: $ROOT_KEYID"
[ "$signer" = "$ROOT_KEYID" ] \
  || { echo "  !! the keyring source was signed by $signer, not by the root key"; exit 1; }
echo "  OK: the keyring source is signed by the root key"

echo
echo "--- B) the fixture signed by a since-revoked subkey ---"
# Same assertion style: the status stream, never the exit code.
gpgv --keyring "$W/keys/packages.gpg" --status-fd 3 "$W/revoked/InRelease" \
     3> "$W/status.b" 2> "$W/gpgv.b" || true
sed 's/^/    /' "$W/gpgv.b"
if grep -qE '^\[GNUPG:\] (REVKEYSIG|KEYREVOKED)' "$W/status.b"; then
  grep -E '^\[GNUPG:\] (REVKEYSIG|KEYREVOKED|EXPKEYSIG)' "$W/status.b" | sed 's/^/    /'
  echo "  OK: reported as signed by a revoked key, not accepted as good"
elif grep -q '^\[GNUPG:\] GOODSIG ' "$W/status.b"; then
  echo "  !! the verifier called this a GOOD signature - revocation was not seen"
  sed 's/^/    /' "$W/status.b"; exit 1
else
  echo "  !! neither a good nor a revoked signature: the fixture may be broken"
  sed 's/^/    /' "$W/status.b"; exit 1
fi

echo
echo "=== B/keyring: PASS ==="
