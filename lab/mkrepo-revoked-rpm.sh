#!/usr/bin/env bash
#
# Build a tiny rpm repository whose repodata is signed by a key that HAS SINCE
# BEEN REVOKED. This is the rpm counterpart of `site/debian-revoked`, for the
# formats the debian line cannot speak for (FINDINGS 10.8).
#
# Why it is built here instead of being committed: the signature has to be made
# with the key *before* it is revoked - gpg refuses to sign with a revoked key -
# and the private half lives only in the `fixture` environment. What is committed
# is the two public states of that same key (keys/revoked-fixture-before.gpg and
# keys/revoked-fixture.gpg), so one artifact can be shown to a consumer under
# both public states of the same key - the pre-revocation export, and the one
# carrying its revocation certificate.
#
# The repository is empty on purpose. What is under test is whether the metadata
# signature is accepted, not whether packages can be installed, and an empty
# repository keeps the two apart.
#
# This file states no verdict, deliberately. What a consumer does with the revoked
# state is measured in consume-revoked-dnf.sh, and the rpm answer is not the
# intuitive one: dnf accepts it (FINDINGS 10.7). An earlier version of this comment
# asserted the opposite, which is the kind of claim that outlives its measurement.
#
#   env: SIGNING_KEY_B64 - base64 of `gpg --armor --export-secret-subkeys "<fpr>!"`
#                          (the pre-revocation export)
#        OUT             - repository root to build
set -euo pipefail

OUT="${OUT:?}"; KEY_B64="${SIGNING_KEY_B64:-}"
[ -n "$KEY_B64" ] || { echo "!! no signing key supplied"; exit 1; }

echo "=== fixture: rpm repository signed by a since-revoked key ==="
# Not `. /etc/os-release`: it defines ARCH and VERSION, which are inputs of
# scripts in this directory (see FINDINGS 3.10).
echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"

echo
echo "--- tooling ---"
dnf install -y -q gnupg2 createrepo_c </dev/null >/dev/null 2>&1 || true
echo "  createrepo_c: $(command -v createrepo_c || echo MISSING)"

echo
echo "--- import the key (its pre-revocation private half) ---"
printf '%s\n' "$KEY_B64" | base64 -d | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64
mapfile -t SUBS < <(gpg --with-colons --list-secret-keys 2>/dev/null \
                    | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}')
if [ "${#SUBS[@]}" -ne 1 ]; then
  echo "  !! expected exactly 1 usable subkey here, found ${#SUBS[@]}"; exit 1
fi
SUB="${SUBS[0]}"
echo "  signing subkey = $SUB"

echo
echo "--- prove this import can actually sign ---"
# The point of the check: what arrives here must be the export taken BEFORE the
# revocation. An import that already carries the revocation certificate would be
# refused by gpg at signing time, and the resulting failure would look like a
# fixture problem rather than the wrong export being uploaded.
PROBE=$(mktemp); ERRF=$(mktemp)
if ! printf 'probe\n' | gpg --batch --yes --local-user "${SUB}!" --detach-sign \
       -o "$PROBE" 2>"$ERRF"; then
  echo "  !! this key cannot sign - is the pre-revocation export the one that was uploaded?"
  sed 's/^/    /' "$ERRF"
  rm -f "$PROBE" "$ERRF"; exit 1
fi
rm -f "$PROBE" "$ERRF"
echo "  OK: the imported key can sign"

echo
echo "--- build an empty repository and sign its metadata ---"
mkdir -p "$OUT/repodata"
createrepo_c "$OUT" >/dev/null
gpg --batch --yes --local-user "${SUB}!" --detach-sign --armor \
    -o "$OUT/repodata/repomd.xml.asc" "$OUT/repodata/repomd.xml"
echo "  repomd.xml.asc = $(wc -c < "$OUT/repodata/repomd.xml.asc" | tr -d ' ') bytes"

echo
echo "--- who signed it (must be the fixture key, and it must look valid *now*) ---"
gpg --verify "$OUT/repodata/repomd.xml.asc" "$OUT/repodata/repomd.xml" 2>&1 | sed 's/^/    /'

echo
echo "--- output ---"
find "$OUT" -type f | sort | sed 's/^/  /'
