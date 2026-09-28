#!/usr/bin/env bash
#
# Stage B for the pacman format: does pacman refuse a database signed by a key
# that has since been revoked?
#
# The other half of FINDINGS 10.8. pacman grants trust out of band with
# `pacman-key --lsign-key` rather than through a gpgkey= line, so the control
# here is built differently from the dnf one - but the same discipline applies:
# ONE artifact, ONE repository configuration, and the only difference between
# the two halves is which public state of the signing key was handed over.
#
#   A. the key as it looked BEFORE the revocation, locally signed -> accepted
#   B. the same key WITH the revocation certificate                 -> refused
#
#   env: PAGES, EXPECT_SHA
set -euo pipefail

PAGES="${PAGES:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys"
source "$(dirname "$0")/lib-site.sh"

REPO=fixture
CONF=/etc/pacman.conf

echo "=== B/revoked (pacman) ==="
# Not `. /etc/os-release` - see FINDINGS 3.10.
echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "  $(pacman --version | head -1)"

echo
echo "--- tooling ---"
if ! grep -qE '^\s*Server' /etc/pacman.d/mirrorlist; then
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
fi
pacman_tools
command -v gpg >/dev/null || { echo "  !! gpg is missing"; exit 1; }
assert_tls "$PAGES/publish.json" || exit 1
if ! gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null | grep -q '^sec'; then
  echo "  (the pacman keyring has no secret key; creating one)"
  pacman-key --init
fi

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- the two public states of one key ---"
fetch "$PAGES/keys/revoked-fixture-before.gpg" "$W/keys/before.gpg"
fetch "$PAGES/keys/revoked-fixture.gpg"        "$W/keys/after.gpg"
sub_before=$(first_sub_fpr "$W/keys/before.gpg")
sub_after=$(first_sub_fpr "$W/keys/after.gpg")
echo "  before: subkey $sub_before"
echo "  after:  subkey $sub_after"
[ "$sub_before" = "$sub_after" ] \
  || { echo "  !! the two files are not two states of the same key"; exit 1; }
echo "  OK: same key, two states"

echo
echo "--- A) the pre-revocation key, locally signed, must accept the database ---"
pacman-key --add "$W/keys/before.gpg" 2>&1 | sed 's/^/    /'
if ! pacman-key --lsign-key "$sub_before" 2>&1 | sed 's/^/    /'; then
  echo "  !! could not locally sign the pre-revocation key, so nothing below would mean anything"
  exit 1
fi
cat >> "$CONF" <<EOF

[$REPO]
SigLevel = Required DatabaseRequired
Server = $PAGES/revoked-pac
EOF
rm -rf /var/lib/pacman/sync/*
if ! pacman -Sy --noconfirm > "$W/a.log" 2>&1; then
  echo "  !! the control was refused, so the second half would mean nothing:"
  sed 's/^/    /' "$W/a.log"; exit 1
fi
seen=$(pacman -Sl "$REPO" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')
echo "  OK: accepted, and it lists: ${seen:-<nothing>}"
[ -n "$seen" ] || { echo "  !! the control listed no package at all"; exit 1; }

echo
echo "--- B) the SAME key, with its revocation certificate, must refuse it ---"
# Drop the trust granted above and hand over the revoked state instead. Note
# that `--lsign-key` may itself refuse - which is also an answer, and one worth
# reporting separately from the database being refused.
pacman-key --delete "$sub_before" >/dev/null 2>&1 || true
rm -rf /var/lib/pacman/sync/*
pacman-key --add "$W/keys/after.gpg" 2>&1 | sed 's/^/    /'
if pacman-key --lsign-key "$sub_after" > "$W/lsign.log" 2>&1; then
  echo "  (pacman-key accepted locally-signing the revoked key - so the question is the database)"
else
  echo "  (pacman-key refused to locally sign the revoked key)"
  grep -iE 'revok|error' "$W/lsign.log" | head -3 | sed 's/^/    /' || true
fi
if pacman -Sy --noconfirm > "$W/b.log" 2>&1; then
  seen=$(pacman -Sl "$REPO" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')
  if [ -n "$seen" ]; then
    echo "  !! pacman accepted a database signed by a revoked key: $seen"; exit 1
  fi
  echo "  (the sync succeeded but the repository is invisible)"
fi
echo "  OK: refused, as it must be"
echo "  --- what pacman actually said (for the record) ---"
grep -iE 'revok|invalid|corrupted|unknown key|signature' "$W/b.log" | head -6 | sed 's/^/    /' || true

echo
echo "=== B/revoked (pacman): PASS ==="
