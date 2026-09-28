#!/usr/bin/env bash
#
# Stage B for the rpm format: DOES dnf refuse metadata signed by a key that has
# since been revoked?
#
# Answer: **no**. FINDINGS 10.7 is the measurement; this script is how it was
# made. FINDINGS 3.1 recorded that revocation is only as good as the verifier,
# and 10.8 recorded that this lab had demonstrated it against `gpgv` (apt's
# backend) and measured nothing for dnf or pacman. This cell measures dnf, and
# the answer is that the revocation certificate is not consulted on this path.
#
# The design is the same-object control that 3.7 asks for, taken to its tightest
# form here: ONE artifact, ONE repository configuration, and the only thing that
# differs between the two halves is which public state of the signing key the
# consumer was given.
#
#   A. gpgkey = the key as it looked BEFORE the revocation -> accepted
#   B. gpgkey = the same key WITH the revocation certificate -> ACCEPTED TOO
#
# Because B is not refused, A is what proves the fixture can be told apart at all
# - if A had been refused too, nothing below would mean anything. The cell
# asserts the observed behaviour rather than the hoped-for one, so that it goes
# red the day dnf starts checking.
#
#   env: PAGES, EXPECT_SHA
set -euo pipefail

PAGES="${PAGES:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys"
source "$(dirname "$0")/lib-site.sh"

REPO=qmdmm-fixture
REPOFILE=/etc/yum.repos.d/qmdmm-fixture.repo

write_repo() {  # write_repo <key-file>
  cat > "$REPOFILE" <<EOF
[$REPO]
name=QMdmm revocation fixture
baseurl=$PAGES/revoked-rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$1
EOF
  sed 's/^/  | /' "$REPOFILE"
}

echo "=== B/revoked (rpm, dnf) ==="
# Not `. /etc/os-release` - see FINDINGS 3.10.
echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "  $(dnf --version 2>/dev/null | head -1)"

echo
echo "--- tooling ---"
dnf install -y -q gnupg2 curl ca-certificates </dev/null >/dev/null 2>&1 || true
assert_tls "$PAGES/publish.json" || exit 1

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- the two public states of one key ---"
fetch "$PAGES/keys/revoked-fixture-before.gpg" "$W/keys/before.gpg"
fetch "$PAGES/keys/revoked-fixture.gpg"        "$W/keys/after.gpg"
# `first_sub_fpr`, NOT `live_sub_fpr`, and deliberately: the whole point here is
# that both files carry the SAME subkey in two public states, and the "after"
# file's only subkey is the revoked one - asking for a *usable* one would return
# nothing and turn "same key, two states" into a false failure.
sub_before=$(first_sub_fpr "$W/keys/before.gpg")
sub_after=$(first_sub_fpr "$W/keys/after.gpg")
echo "  before: subkey $sub_before"
echo "  after:  subkey $sub_after"
[ "$sub_before" = "$sub_after" ] \
  || { echo "  !! the two files are not two states of the same key"; exit 1; }
echo "  OK: same key, two states"

echo
echo "--- A) the pre-revocation key must accept the repository ---"
write_repo "$W/keys/before.gpg"
rm -rf /var/cache/dnf /var/cache/libdnf5; dnf clean all >/dev/null 2>&1 || true
dnf -y -q makecache > "$W/a.log" 2>&1 || true
echo "  --- what dnf said ---"
sed 's/^/    /' "$W/a.log"
# The control. Because the second half turns out to be accepted as well (see the
# finding there), this half is what establishes that "accepted" is a real
# observation and not a fixture that nothing could ever reject: same artifact,
# same configuration, one key file apart.
if grep -qiE 'signature verification error|GPG check FAILED|Bad PGP signature|Signing key not found' "$W/a.log"; then
  echo "  !! the control was refused, so nothing below would mean anything"
  exit 1
fi
echo "  OK: accepted (an empty repository, as designed - the metadata verified)"

echo
echo "--- B) the SAME key, with its revocation certificate ---"
write_repo "$W/keys/after.gpg"
rm -rf /var/cache/dnf /var/cache/libdnf5; dnf clean all >/dev/null 2>&1 || true
dnf -y -q makecache > "$W/b.log" 2>&1 || true
echo "  --- what dnf said ---"
sed 's/^/    /' "$W/b.log"

# The finding, and it is the opposite of what this cell was written expecting:
# dnf ACCEPTS metadata signed by a key that has since been revoked. Its output
# here is what the control produced, line for line - same import, same
# "Metadata cache created." - so the revocation certificate is not consulted on
# this path. That dnf verifies signatures at all is not in doubt: stage B's
# twelve rows show it refusing a repository whose gpgkey= names only the root
# key, with "repomd.xml GPG signature verification error".
#
# The assertion is therefore inverted on purpose, the way fedora:43 was handled:
# the day dnf starts checking revocation, this goes red and whoever reads it
# learns that FINDINGS 10.7 needs revisiting. A cell asserting "dnf refuses it"
# would have been red forever, and would have been read as a broken fixture.
if ! grep -q 'Metadata cache created' "$W/b.log"; then
  echo "  !! dnf did NOT accept the revoked-key metadata - it now checks revocation,"
  echo "     so FINDINGS 10.7 is out of date and this cell should be flipped back"
  exit 1
fi
if grep -qiE 'signature verification error|Bad PGP signature|Signing key not found' "$W/b.log"; then
  echo "  !! dnf complained about the signature after all - contradicts the note above"
  exit 1
fi
echo "  OK: dnf accepted it, exactly as it accepted the control"
echo "      -> revocation is NOT enforced by this consumer (FINDINGS 10.7)"

echo
echo "=== B/revoked (rpm, dnf): PASS ==="
